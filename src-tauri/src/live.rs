//! Agent liveness: read sidecar status files and fold into an effective state.
//! Mirrors the reference algorithm in `aib sessions state` (Plan 1).

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum PidLiveness {
    Alive,
    Dead,
    Unknown,
}

/// kill(pid,0): 0 => alive; EPERM => alive (process exists, not ours); else dead. pid<=0 => unknown.
pub fn pid_liveness(pid: i32) -> PidLiveness {
    if pid <= 0 {
        return PidLiveness::Unknown;
    }
    let r = unsafe { libc::kill(pid as libc::pid_t, 0) };
    if r == 0 {
        return PidLiveness::Alive;
    }
    match std::io::Error::last_os_error().raw_os_error() {
        Some(e) if e == libc::EPERM => PidLiveness::Alive,
        _ => PidLiveness::Dead,
    }
}

/// Hook-written status sidecar. Extra aib fields (version, session_id, source,
/// confidence, lstart, comm, cwd) are ignored by serde — we only need these.
#[derive(Debug, Clone, Deserialize)]
pub struct StatusFile {
    pub state: String,
    pub run_id: String,
    pub ts: i64,
    #[serde(default)]
    pub pid: i32,
    // Present for diagnostics/backward compatibility in hook sidecars, but
    // effective-state folding currently does not need to inspect them.
    #[allow(dead_code)]
    #[serde(default)]
    pub event: String,
    #[allow(dead_code)]
    #[serde(default)]
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct AckFile {
    pub acked_run_id: String,
    #[serde(default)]
    pub ack_ts: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Effective {
    Working,
    WorkingStale,
    Blocked,
    Crashed,
    Interrupted,
    Done,
    Idle,
    None,
}

/// Pure fold — MUST match `aib sessions state` (Plan 1) exactly.
pub fn fold(
    s: &StatusFile,
    ack: Option<&AckFile>,
    now: i64,
    live: PidLiveness,
    stale_working: i64,
) -> Effective {
    let age = now - s.ts;
    // ack must match the run AND not predate this status (aib reuses run_id across a
    // session's turns; a later done than the ack is a new turn-end, not acknowledged).
    let acked = ack.is_some_and(|a| a.acked_run_id == s.run_id && a.ack_ts >= s.ts);
    match s.state.as_str() {
        "done" => {
            if acked {
                Effective::Idle
            } else {
                Effective::Done
            }
        }
        "blocked" => match live {
            PidLiveness::Dead => Effective::Crashed,
            _ => Effective::Blocked,
        },
        "working" => match live {
            PidLiveness::Dead => Effective::Interrupted,
            _ => {
                if age > stale_working {
                    Effective::WorkingStale
                } else {
                    Effective::Working
                }
            }
        },
        _ => Effective::None,
    }
}

/// STALE_WORKING seconds; reads the SAME env as Plan 1's bash reference (default 180).
pub fn stale_working_secs() -> i64 {
    std::env::var("AIB_LIVE_STALE_WORKING")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(180)
}

/// One session's folded liveness; serialized snake_case to match the TS `LiveState`.
#[derive(Debug, Clone, Serialize)]
pub struct LiveState {
    pub session_id: String,
    pub effective: Effective,
    pub state: String,
    pub age_sec: i64,
    pub pid: i32,
    pub pid_alive: bool,
    pub pid_unknown: bool,
    pub run_id: String,
}

fn now_epoch() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Read + fold every `sessions/.live/*.status` in a barrack (joining its `.ack`).
/// Missing dir => empty. Malformed status (serde fail, e.g. missing `ts`) => skipped
/// (parity with the bash reference's `none`).
pub fn read_live_states(barrack_path: &str) -> Result<Vec<LiveState>, String> {
    let dir = std::path::PathBuf::from(barrack_path).join("sessions/.live");
    let rd = match std::fs::read_dir(&dir) {
        Ok(r) => r,
        Err(_) => return Ok(vec![]),
    };
    let now = now_epoch();
    let stale = stale_working_secs();
    let mut out = Vec::new();
    for e in rd.flatten() {
        let p = e.path();
        if p.extension().and_then(|x| x.to_str()) != Some("status") {
            continue;
        }
        let raw = match std::fs::read_to_string(&p) {
            Ok(r) => r,
            Err(_) => continue,
        };
        let s: StatusFile = match serde_json::from_str(&raw) {
            Ok(s) => s,
            Err(_) => continue,
        };
        let ack: Option<AckFile> = std::fs::read_to_string(p.with_extension("ack"))
            .ok()
            .and_then(|r| serde_json::from_str(&r).ok());
        let live = pid_liveness(s.pid);
        let eff = fold(&s, ack.as_ref(), now, live, stale);
        let sid = p
            .file_stem()
            .and_then(|x| x.to_str())
            .unwrap_or("")
            .to_string();
        out.push(LiveState {
            session_id: sid,
            effective: eff,
            state: s.state.clone(),
            age_sec: now - s.ts,
            pid: s.pid,
            pid_alive: matches!(live, PidLiveness::Alive),
            pid_unknown: matches!(live, PidLiveness::Unknown),
            run_id: s.run_id,
        });
    }
    Ok(out)
}

#[tauri::command]
pub fn get_live_states(barrack_path: String) -> Result<Vec<LiveState>, String> {
    read_live_states(&barrack_path)
}

/// Operator-written `.ack` (atomic temp+rename). Lets a `done` session fold to `idle`.
pub fn write_ack(barrack_path: &str, session_id: &str, run_id: &str) -> Result<(), String> {
    use std::io::Write;
    // Whitelist: aib session ids are [A-Za-z0-9_-]+ — rejects '/', '.', '\\', drive
    // prefixes, control chars, and any path-escape in one check.
    if session_id.is_empty()
        || !session_id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return Err("invalid session_id".into());
    }
    let dir = std::path::PathBuf::from(barrack_path).join("sessions/.live");
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let body = serde_json::json!({ "version": 1, "acked_run_id": run_id, "ack_ts": now_epoch() })
        .to_string();
    let mut tf = tempfile::NamedTempFile::new_in(&dir).map_err(|e| e.to_string())?;
    tf.write_all(body.as_bytes()).map_err(|e| e.to_string())?;
    tf.persist(dir.join(format!("{session_id}.ack")))
        .map_err(|e| e.to_string())?; // atomic rename
    Ok(())
}

#[tauri::command]
pub fn ack_live_state(
    barrack_path: String,
    session_id: String,
    run_id: String,
) -> Result<(), String> {
    write_ack(&barrack_path, &session_id, &run_id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;
    use PidLiveness::*;

    const STALE: i64 = 180;

    fn now_s() -> i64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64
    }

    fn st(state: &str, ts: i64, run_id: &str) -> StatusFile {
        StatusFile {
            state: state.into(),
            run_id: run_id.into(),
            ts,
            pid: 0,
            event: String::new(),
            reason: None,
        }
    }

    #[test]
    fn current_is_alive() {
        assert_eq!(pid_liveness(std::process::id() as i32), PidLiveness::Alive);
    }

    #[test]
    fn nonpositive_is_unknown() {
        assert_eq!(pid_liveness(0), PidLiveness::Unknown);
        assert_eq!(pid_liveness(-1), PidLiveness::Unknown);
    }

    #[test]
    fn exited_child_is_dead() {
        let mut c = std::process::Command::new("true").spawn().unwrap();
        let pid = c.id() as i32;
        c.wait().unwrap();
        assert_eq!(pid_liveness(pid), PidLiveness::Dead);
    }

    #[test]
    fn fold_matrix() {
        let now = 1_000_000i64;
        // blocked: alive/unknown -> blocked (any age); dead -> crashed
        assert_eq!(fold(&st("blocked", now - 99999, "r"), None, now, Alive, STALE), Effective::Blocked);
        assert_eq!(fold(&st("blocked", now, "r"), None, now, Unknown, STALE), Effective::Blocked);
        assert_eq!(fold(&st("blocked", now, "r"), None, now, Dead, STALE), Effective::Crashed);
        // working: dead -> interrupted; alive/unknown -> age-based (boundary: > STALE, not >=)
        assert_eq!(fold(&st("working", now, "r"), None, now, Alive, STALE), Effective::Working);
        assert_eq!(fold(&st("working", now - STALE, "r"), None, now, Alive, STALE), Effective::Working); // ==STALE stays working
        assert_eq!(fold(&st("working", now - STALE - 1, "r"), None, now, Alive, STALE), Effective::WorkingStale); // >STALE
        assert_eq!(fold(&st("working", now - STALE - 1, "r"), None, now, Unknown, STALE), Effective::WorkingStale);
        assert_eq!(fold(&st("working", now, "r"), None, now, Dead, STALE), Effective::Interrupted);
        // done: unacked -> done (alive/dead/unknown); ack match -> idle; ack mismatch -> done
        assert_eq!(fold(&st("done", now, "r"), None, now, Alive, STALE), Effective::Done);
        assert_eq!(fold(&st("done", now, "r"), None, now, Dead, STALE), Effective::Done);
        assert_eq!(fold(&st("done", now, "RID"), Some(&AckFile { acked_run_id: "RID".into(), ack_ts: now }), now, Alive, STALE), Effective::Idle);
        assert_eq!(fold(&st("done", now, "RID"), Some(&AckFile { acked_run_id: "OTHER".into(), ack_ts: now }), now, Alive, STALE), Effective::Done);
        // malformed state -> none
        assert_eq!(fold(&st("weird", now, "r"), None, now, Alive, STALE), Effective::None);
    }

    #[test]
    fn effective_serializes_snake_case() {
        assert_eq!(serde_json::to_string(&Effective::WorkingStale).unwrap(), "\"working_stale\"");
        assert_eq!(serde_json::to_string(&Effective::None).unwrap(), "\"none\"");
    }

    #[test]
    fn read_states_reads_folds_and_joins_ack() {
        let tmp = TempDir::new().unwrap();
        let live = tmp.path().join("sessions/.live");
        fs::create_dir_all(&live).unwrap();
        let me = std::process::id();
        fs::write(
            live.join("claude-a.status"),
            format!(
                r#"{{"version":1,"session_id":"claude-a","run_id":"RA","state":"working","event":"PreToolUse","reason":null,"source":"claude_hook","confidence":"high","ts":{},"pid":{}}}"#,
                now_s(),
                me
            ),
        )
        .unwrap();
        fs::write(
            live.join("claude-b.status"),
            r#"{"version":1,"session_id":"claude-b","run_id":"RB","state":"done","event":"Stop","reason":"turn_complete","source":"claude_hook","confidence":"high","ts":1,"pid":0}"#,
        )
        .unwrap();
        fs::write(live.join("claude-b.ack"), r#"{"version":1,"acked_run_id":"RB","ack_ts":2}"#).unwrap();
        let mut v = read_live_states(tmp.path().to_str().unwrap()).unwrap();
        v.sort_by(|a, b| a.session_id.cmp(&b.session_id));
        assert_eq!(v.len(), 2);
        assert_eq!(v[0].effective, Effective::Working);
        assert!(v[0].pid_alive);
        assert_eq!(v[1].effective, Effective::Idle); // done + matching ack
    }

    #[test]
    fn read_states_missing_dir_is_empty() {
        let tmp = TempDir::new().unwrap();
        assert!(read_live_states(tmp.path().to_str().unwrap()).unwrap().is_empty());
    }

    // REV3 B2: a .status missing a required field (ts) fails serde -> excluded (parity with bash 'none').
    #[test]
    fn read_states_excludes_malformed_missing_ts() {
        let tmp = TempDir::new().unwrap();
        let live = tmp.path().join("sessions/.live");
        fs::create_dir_all(&live).unwrap();
        fs::write(
            live.join("bad.status"),
            r#"{"version":1,"session_id":"bad","run_id":"R","state":"working"}"#,
        )
        .unwrap();
        let v = read_live_states(tmp.path().to_str().unwrap()).unwrap();
        assert!(v.iter().all(|s| s.session_id != "bad"));
    }

    #[test]
    fn ack_then_fold_is_idle() {
        let tmp = TempDir::new().unwrap();
        let live = tmp.path().join("sessions/.live");
        fs::create_dir_all(&live).unwrap();
        fs::write(
            live.join("s1.status"),
            r#"{"version":1,"session_id":"s1","run_id":"RUN9","state":"done","event":"Stop","reason":null,"source":"claude_hook","confidence":"high","ts":1,"pid":0}"#,
        )
        .unwrap();
        write_ack(tmp.path().to_str().unwrap(), "s1", "RUN9").unwrap();
        let p = live.join("s1.ack");
        assert!(p.exists());
        let a: AckFile = serde_json::from_str(&fs::read_to_string(&p).unwrap()).unwrap();
        assert_eq!(a.acked_run_id, "RUN9");
        let v = read_live_states(tmp.path().to_str().unwrap()).unwrap();
        assert_eq!(v[0].effective, Effective::Idle);
    }

    #[test]
    fn ack_rejects_path_escape() {
        let tmp = TempDir::new().unwrap();
        assert!(write_ack(tmp.path().to_str().unwrap(), "../evil", "R").is_err());
    }

    // Regression (Codex MAJOR): aib reuses one run_id across all turns of a session.
    // ack stores run_id + ack_ts; a LATER done in the same run (bigger ts) must NOT be
    // pre-acked just because the run_id matches — else the user misses later turn-ends.
    #[test]
    fn ack_does_not_preack_later_done_same_run() {
        let now = 1_000_000i64;
        let ack = AckFile { acked_run_id: "RID".into(), ack_ts: now };
        // the done that was acknowledged -> idle
        assert_eq!(fold(&st("done", now, "RID"), Some(&ack), now, Alive, STALE), Effective::Idle);
        // a NEW done in the same run, after the ack -> still Done (not pre-acked)
        assert_eq!(fold(&st("done", now + 50, "RID"), Some(&ack), now + 50, Alive, STALE), Effective::Done);
    }
}
