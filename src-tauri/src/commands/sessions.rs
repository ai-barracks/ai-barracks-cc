use regex::Regex;
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};

#[derive(Debug, Serialize, Clone)]
pub struct SessionInfo {
    pub id: String,
    pub client: String,
    pub started: String,
    pub ended: String,
    pub status: String,
    pub task: String,
    pub continues: String,
}

#[derive(Debug, Serialize, Clone)]
pub struct SessionDetail {
    pub info: SessionInfo,
    pub log: Vec<String>,
    pub decisions: Vec<String>,
    pub blockers: Vec<String>,
    pub wiki_extractions: Vec<String>,
    pub identity_suggestions: Vec<String>,
    pub raw_content: String,
    /// "unsealed" | "intact" | "modified" | "invalid" — see `seal_status`.
    pub seal_status: String,
}

fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{:02x}", b))
        .collect()
}

/// The seal `aib` writes at SessionEnd: `sessions/.seals/<id>.sha256`.
#[derive(Debug, PartialEq)]
enum SealRead {
    Missing,
    /// Exists but cannot be trusted or read: symlinked/non-directory `.seals`, symlinked
    /// or non-regular seal (a FIFO would block the read), or an I/O error.
    Unusable,
    Record(String),
}

fn read_seal(barrack: &Path, session_id: &str) -> SealRead {
    let seals_dir = barrack.join("sessions").join(".seals");
    match fs::symlink_metadata(&seals_dir) {
        Err(e) if e.kind() == ErrorKind::NotFound => return SealRead::Missing,
        Err(_) => return SealRead::Unusable,
        Ok(meta) if !meta.file_type().is_dir() => return SealRead::Unusable,
        Ok(_) => {}
    }
    let path = seals_dir.join(format!("{}.sha256", session_id));
    match fs::symlink_metadata(&path) {
        Err(e) if e.kind() == ErrorKind::NotFound => SealRead::Missing,
        Err(_) => SealRead::Unusable,
        Ok(meta) if !meta.file_type().is_file() => SealRead::Unusable,
        Ok(_) => fs::read_to_string(&path)
            .map(SealRead::Record)
            .unwrap_or(SealRead::Unusable),
    }
}

/// Compare an ended session file against its seal, one `shasum -a 256` line
/// "<hex>  sessions/<id>.md". A seal that exists but cannot be used is "invalid",
/// never "unsealed", so breaking the seal does not hide a change. Mirrors
/// `aib sessions verify`, which also rejects a symlinked session file.
fn seal_status(
    seal: &SealRead,
    session_id: &str,
    file_bytes: &[u8],
    md_is_symlink: bool,
) -> &'static str {
    let record = match seal {
        SealRead::Missing => return "unsealed",
        SealRead::Unusable => return "invalid",
        SealRead::Record(content) => content.trim_end_matches('\n'),
    };
    if md_is_symlink {
        return "invalid";
    }
    let expected_path = format!("sessions/{}.md", session_id);
    let sealed_hex = match record.split_once("  ") {
        Some((hex, path))
            if !record.contains('\n')
                && hex.len() == 64
                && hex.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
                && path == expected_path =>
        {
            hex
        }
        _ => return "invalid",
    };
    if sealed_hex == sha256_hex(file_bytes) {
        "intact"
    } else {
        "modified"
    }
}

fn parse_field(content: &str, field: &str) -> String {
    let pattern = format!(r"\*\*{}\*\*:\s*(.+)", regex::escape(field));
    Regex::new(&pattern)
        .ok()
        .and_then(|re| re.captures(content))
        .map(|caps| caps[1].trim().to_string())
        .unwrap_or_default()
}

fn parse_section(content: &str, section: &str) -> Vec<String> {
    let header = format!("## {}", section);
    let mut in_section = false;
    let mut items = Vec::new();

    for line in content.lines() {
        if line.trim().starts_with(&header) {
            in_section = true;
            continue;
        }
        if in_section && line.starts_with("## ") {
            break;
        }
        if in_section {
            let trimmed = line.trim();
            if let Some(stripped) = trimmed.strip_prefix("- ") {
                items.push(stripped.to_string());
            } else if !trimmed.is_empty() && !trimmed.starts_with("<!--") {
                items.push(trimmed.to_string());
            }
        }
    }
    items
}

fn detect_client(id: &str) -> String {
    if id.starts_with("claude") {
        "Claude Code".to_string()
    } else if id.starts_with("gemini") {
        "Gemini CLI".to_string()
    } else if id.starts_with("codex") {
        "Codex CLI".to_string()
    } else {
        "Unknown".to_string()
    }
}

#[tauri::command]
pub fn get_sessions(barrack_path: String) -> Result<Vec<SessionInfo>, String> {
    let sessions_dir = PathBuf::from(&barrack_path).join("sessions");
    let mut sessions = Vec::new();

    let entries =
        fs::read_dir(&sessions_dir).map_err(|e| format!("sessions 디렉토리 읽기 실패: {}", e))?;

    for entry in entries.flatten() {
        let filename = entry.file_name().to_string_lossy().to_string();
        if !filename.ends_with(".md") || filename == ".active" {
            continue;
        }

        let id = filename.trim_end_matches(".md").to_string();
        let content = fs::read_to_string(entry.path()).unwrap_or_default();

        let client_field = parse_field(&content, "Client");
        let client = if client_field.is_empty() {
            detect_client(&id)
        } else {
            client_field
        };

        sessions.push(SessionInfo {
            id: id.clone(),
            client,
            started: parse_field(&content, "Started"),
            ended: parse_field(&content, "Ended"),
            status: parse_field(&content, "Status"),
            task: parse_field(&content, "Task"),
            continues: parse_field(&content, "Continues"),
        });
    }

    sessions.sort_by(|a, b| b.id.cmp(&a.id));
    Ok(sessions)
}

#[tauri::command]
pub fn get_session_detail(
    barrack_path: String,
    session_id: String,
) -> Result<SessionDetail, String> {
    let barrack = PathBuf::from(&barrack_path);
    let file_path = barrack.join("sessions").join(format!("{}.md", session_id));

    // The same bytes feed the seal hash and the parsed/raw content. The seal is read
    // before and after: if SessionEnd completed + sealed in between, comparing the old
    // bytes with the new seal would be a false "modified", so re-read the file once.
    let read_file = || fs::read(&file_path).map_err(|e| format!("세션 파일 읽기 실패: {}", e));
    let mut seal = read_seal(&barrack, &session_id);
    let mut bytes = read_file()?;
    let seal_after = read_seal(&barrack, &session_id);
    if seal_after != seal {
        seal = seal_after;
        bytes = read_file()?;
    }
    let md_is_symlink = fs::symlink_metadata(&file_path)
        .map(|meta| meta.file_type().is_symlink())
        .unwrap_or(false);
    let seal_status = seal_status(&seal, &session_id, &bytes, md_is_symlink).to_string();
    let content = String::from_utf8_lossy(&bytes).into_owned();

    let client_field = parse_field(&content, "Client");
    let client = if client_field.is_empty() {
        detect_client(&session_id)
    } else {
        client_field
    };

    let info = SessionInfo {
        id: session_id,
        client,
        started: parse_field(&content, "Started"),
        ended: parse_field(&content, "Ended"),
        status: parse_field(&content, "Status"),
        task: parse_field(&content, "Task"),
        continues: parse_field(&content, "Continues"),
    };

    Ok(SessionDetail {
        info,
        log: parse_section(&content, "Log"),
        decisions: parse_section(&content, "Decisions"),
        blockers: parse_section(&content, "Blockers"),
        wiki_extractions: parse_section(&content, "Wiki Extractions"),
        identity_suggestions: parse_section(&content, "Identity Suggestions"),
        raw_content: content,
        seal_status,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    const SID: &str = "claude-20261014-1000";
    const BODY: &str = "- **Status**: completed\n## Log\n- [10:00] work\n";

    fn barrack_with(body: &str, seal: Option<&str>) -> TempDir {
        let tmp = TempDir::new().unwrap();
        let sessions = tmp.path().join("sessions");
        fs::create_dir_all(sessions.join(".seals")).unwrap();
        fs::write(sessions.join(format!("{SID}.md")), body).unwrap();
        if let Some(seal) = seal {
            fs::write(sessions.join(".seals").join(format!("{SID}.sha256")), seal).unwrap();
        }
        tmp
    }

    fn seal_line(body: &str) -> String {
        format!("{}  sessions/{SID}.md\n", sha256_hex(body.as_bytes()))
    }

    fn status_of(tmp: &TempDir) -> String {
        get_session_detail(tmp.path().to_string_lossy().into_owned(), SID.to_string())
            .unwrap()
            .seal_status
    }

    #[test]
    fn sha256_hex_matches_known_vector() {
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn seal_status_intact_when_hash_matches() {
        let tmp = barrack_with(BODY, Some(&seal_line(BODY)));
        assert_eq!(status_of(&tmp), "intact");
    }

    #[test]
    fn seal_status_modified_after_change() {
        let tmp = barrack_with(&format!("{BODY}- [11:00] edited\n"), Some(&seal_line(BODY)));
        assert_eq!(status_of(&tmp), "modified");
    }

    #[test]
    fn seal_status_unsealed_without_seal_file() {
        let tmp = barrack_with(BODY, None);
        assert_eq!(status_of(&tmp), "unsealed");
    }

    #[test]
    fn seal_status_invalid_for_malformed_or_mismatched_seal() {
        let garbage = barrack_with(BODY, Some("garbage\n"));
        assert_eq!(status_of(&garbage), "invalid");
        let other_path = seal_line(BODY).replace(&format!("sessions/{SID}.md"), "sessions/other.md");
        let mismatched = barrack_with(BODY, Some(&other_path));
        assert_eq!(status_of(&mismatched), "invalid");
        let two_records = format!("{}{}", seal_line(BODY), seal_line(BODY));
        let multi = barrack_with(BODY, Some(&two_records));
        assert_eq!(status_of(&multi), "invalid");
    }

    #[test]
    fn seal_status_invalid_when_seals_dir_is_symlink() {
        let tmp = barrack_with(BODY, None);
        let elsewhere = TempDir::new().unwrap();
        fs::write(elsewhere.path().join(format!("{SID}.sha256")), seal_line(BODY)).unwrap();
        let seals = tmp.path().join("sessions").join(".seals");
        fs::remove_dir(&seals).unwrap();
        std::os::unix::fs::symlink(elsewhere.path(), &seals).unwrap();
        assert_eq!(status_of(&tmp), "invalid");
    }

    #[test]
    fn seal_status_invalid_for_non_regular_seal_without_blocking() {
        let tmp = barrack_with(BODY, None);
        let fifo = tmp.path().join("sessions/.seals").join(format!("{SID}.sha256"));
        let made = std::process::Command::new("mkfifo").arg(&fifo).status().unwrap();
        assert!(made.success());
        assert_eq!(status_of(&tmp), "invalid"); // would block forever if the FIFO were read
    }

    #[test]
    fn seal_status_invalid_when_sealed_session_file_is_symlink() {
        let tmp = barrack_with(BODY, Some(&seal_line(BODY)));
        let real = tmp.path().join("real.md");
        fs::write(&real, BODY).unwrap();
        let md = tmp.path().join("sessions").join(format!("{SID}.md"));
        fs::remove_file(&md).unwrap();
        std::os::unix::fs::symlink(&real, &md).unwrap();
        assert_eq!(status_of(&tmp), "invalid");
    }

    #[test]
    fn session_detail_serializes_seal_status_key() {
        let tmp = barrack_with(BODY, Some(&seal_line(BODY)));
        let detail =
            get_session_detail(tmp.path().to_string_lossy().into_owned(), SID.to_string()).unwrap();
        let json = serde_json::to_value(&detail).unwrap();
        assert_eq!(json["seal_status"], "intact");
        assert_eq!(json["raw_content"], BODY);
    }
}
