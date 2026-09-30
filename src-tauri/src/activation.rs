//! Opt-in KST activation. No catch-up, retries, project context or API-key fallback.
use chrono::{DateTime, Duration as ChronoDuration, FixedOffset, TimeZone, Timelike, Utc};
use serde::{Deserialize, Serialize};
#[cfg(unix)]
use std::os::{
    fd::AsRawFd,
    unix::{
        fs::{OpenOptionsExt, PermissionsExt},
        process::CommandExt,
    },
};
use std::{
    collections::BTreeMap,
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{
        atomic::{AtomicBool, AtomicI64, AtomicU64, Ordering},
        Arc, Mutex,
    },
    thread,
    time::{Duration, Instant},
};

const HOURS: [u32; 4] = [6, 11, 16, 21];
const PROMPT: &str = "Reply exactly OK. Do not use any tools.";
const HISTORY_LIMIT: usize = 80;
const OUTPUT_LIMIT: usize = 64 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ActivationConfig {
    pub enabled: bool,
    pub claude: bool,
    pub codex: bool,
}
impl Default for ActivationConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            claude: true,
            codex: true,
        }
    }
}
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "lowercase")]
enum Provider {
    Claude,
    Codex,
}
impl Provider {
    fn binary(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
        }
    }
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ActivationRun {
    provider: Provider,
    slot: String,
    status: String,
    detail: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
struct Document {
    #[serde(default = "schema_version")]
    version: u32,
    config: ActivationConfig,
    last_claimed: BTreeMap<Provider, i64>,
    history: Vec<ActivationRun>,
}
fn schema_version() -> u32 {
    1
}
impl Default for Document {
    fn default() -> Self {
        Self {
            version: 1,
            config: ActivationConfig::default(),
            last_claimed: BTreeMap::new(),
            history: Vec::new(),
        }
    }
}
#[derive(Serialize)]
pub struct ActivationView {
    config: ActivationConfig,
    available: bool,
    error: Option<String>,
    next_slot: Option<String>,
    history: Vec<ActivationRun>,
}
struct Core {
    doc: Mutex<Document>,
    path: Option<PathBuf>,
    error: Mutex<Option<String>>,
    // Keep flock alive for this process; second instances cannot schedule or save.
    _lock: Option<File>,
    generation: AtomicU64,
    armed_after: AtomicI64,
    shutdown: AtomicBool,
    active_pids: Mutex<Vec<u32>>,
}
pub struct ActivationScheduler(Arc<Core>);

fn kst() -> FixedOffset {
    FixedOffset::east_opt(9 * 3600).unwrap()
}
fn slot_at(now: DateTime<Utc>) -> Option<DateTime<Utc>> {
    let local = now.with_timezone(&kst());
    if HOURS.contains(&local.hour()) && local.minute() == 0 {
        Some(
            local
                .with_second(0)?
                .with_nanosecond(0)?
                .with_timezone(&Utc),
        )
    } else {
        None
    }
}
fn next_slot(now: DateTime<Utc>) -> DateTime<Utc> {
    let local = now.with_timezone(&kst());
    for day in 0..=1 {
        let date = local.date_naive() + ChronoDuration::days(day);
        for hour in HOURS {
            let slot = kst()
                .from_local_datetime(&date.and_hms_opt(hour, 0, 0).unwrap())
                .single()
                .unwrap()
                .with_timezone(&Utc);
            if slot > now {
                return slot;
            }
        }
    }
    unreachable!()
}
fn format_slot(slot: DateTime<Utc>) -> String {
    slot.with_timezone(&kst()).to_rfc3339()
}
fn persist(path: &Path, doc: &Document) -> Result<(), String> {
    let mut temp = tempfile::NamedTempFile::new_in(path.parent().ok_or("Invalid schedule path")?)
        .map_err(|_| "Cannot write schedule")?;
    #[cfg(unix)]
    temp.as_file()
        .set_permissions(fs::Permissions::from_mode(0o600))
        .map_err(|_| "Cannot secure schedule")?;
    serde_json::to_writer_pretty(&mut temp, doc).map_err(|_| "Cannot encode schedule")?;
    temp.flush()
        .and_then(|_| temp.as_file().sync_all())
        .map_err(|_| "Cannot flush schedule")?;
    temp.persist(path).map_err(|_| "Cannot persist schedule")?;
    File::open(path.parent().unwrap())
        .and_then(|f| f.sync_all())
        .map_err(|_| "Cannot flush schedule directory")?;
    Ok(())
}
impl ActivationScheduler {
    pub fn new(dir: &Path) -> Self {
        match Self::load(dir) {
            Ok(core) => Self(Arc::new(core)),
            Err(error) => Self::unavailable(&error),
        }
    }
    pub fn unavailable(error: &str) -> Self {
        Self(Arc::new(Core {
            doc: Mutex::new(Document::default()),
            path: None,
            error: Mutex::new(Some(error.into())),
            _lock: None,
            generation: AtomicU64::new(0),
            armed_after: AtomicI64::new(Utc::now().timestamp()),
            shutdown: AtomicBool::new(false),
            active_pids: Mutex::new(Vec::new()),
        }))
    }
    fn load(dir: &Path) -> Result<Core, String> {
        fs::create_dir_all(dir).map_err(|_| "Schedule storage unavailable")?;
        let mut options = OpenOptions::new();
        options.create(true).read(true).write(true).truncate(false);
        #[cfg(unix)]
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
        let lock = options
            .open(dir.join("activation.lock"))
            .map_err(|_| "Cannot open schedule lock")?;
        #[cfg(unix)]
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err("Another CommandCenter instance owns the activation scheduler".into());
        }
        #[cfg(not(unix))]
        return Err("Activation currently requires macOS/Linux process isolation".into());
        let path = dir.join("activation.json");
        let mut doc: Document = if path.exists() {
            let metadata = fs::symlink_metadata(&path).map_err(|_| "Cannot inspect schedule")?;
            if !metadata.is_file() || metadata.len() > 256 * 1024 {
                return Err("Invalid schedule file; activation disabled".into());
            }
            serde_json::from_slice(&fs::read(&path).map_err(|_| "Cannot read schedule")?)
                .map_err(|_| "Invalid schedule file; activation disabled")?
        } else {
            Document::default()
        };
        if doc.version != 1 {
            return Err("Unsupported schedule version; activation disabled".into());
        }
        if doc.config.enabled && !doc.config.claude && !doc.config.codex {
            return Err("Invalid provider selection".into());
        }
        // A claim survives crashes. Never retry a possibly transmitted request.
        for run in &mut doc.history {
            if run.status == "running" || run.status == "pending" {
                run.status = "interrupted".into();
                run.detail = "App exited; not retried".into();
            }
        }
        doc.history.truncate(HISTORY_LIMIT);
        persist(&path, &doc)?;
        Ok(Core {
            doc: Mutex::new(doc),
            path: Some(path),
            error: Mutex::new(None),
            _lock: Some(lock),
            generation: AtomicU64::new(0),
            armed_after: AtomicI64::new(Utc::now().timestamp()),
            shutdown: AtomicBool::new(false),
            active_pids: Mutex::new(Vec::new()),
        })
    }
    pub fn start(&self) {
        if self.0.path.is_none() {
            return;
        }
        let core = self.0.clone();
        thread::spawn(move || {
            while !core.shutdown.load(Ordering::SeqCst) {
                if let Some(slot) = slot_at(Utc::now()) {
                    let generation = core.generation.load(Ordering::SeqCst);
                    let providers = core.claim(slot);
                    for provider in providers {
                        let result = if core.cancelled(generation) {
                            Err("Cancelled after settings changed".into())
                        } else {
                            if core.mark_running(provider, slot) {
                                activate(provider, &core, generation)
                            } else {
                                Err("Schedule storage failed before dispatch".into())
                            }
                        };
                        core.finish(provider, slot, result);
                    }
                }
                thread::sleep(Duration::from_secs(5));
            }
        });
    }
    pub fn stop(&self) {
        self.0.shutdown.store(true, Ordering::SeqCst);
        self.0.cancel_work();
    }

    fn view(&self) -> ActivationView {
        let doc = self.0.doc.lock().unwrap();
        let error = self.0.error.lock().unwrap().clone();
        ActivationView {
            config: doc.config.clone(),
            available: error.is_none(),
            error: error.clone(),
            next_slot: if doc.config.enabled && error.is_none() {
                Some(format_slot(next_slot(Utc::now())))
            } else {
                None
            },
            history: doc.history.clone(),
        }
    }
    fn save(&self, config: ActivationConfig) -> Result<ActivationView, String> {
        if config.enabled && !config.claude && !config.codex {
            return Err("Select at least one CLI".into());
        }
        {
            let mut doc = self.0.doc.lock().unwrap();
            if !config.enabled {
                // OFF cancels in-flight work even if disk persistence is failing.
                doc.config = config.clone();
                self.0.cancel_work();
            }
            if self.0.path.is_none() {
                return Err("Scheduler unavailable; another instance or invalid storage".into());
            }
            if config.enabled && self.0.error.lock().unwrap().is_some() {
                return Err(
                    "Scheduler unavailable; restart after resolving storage/instance error".into(),
                );
            }
            let mut updated = doc.clone();
            updated.config = config;
            if let Err(error) = persist(self.0.path.as_ref().unwrap(), &updated) {
                *self.0.error.lock().unwrap() = Some(error.clone());
                return Err(error);
            }
            *doc = updated;
            // Even at xx:00:00, ON means the next future slot, not 'run now'.
            self.0
                .armed_after
                .store(Utc::now().timestamp(), Ordering::SeqCst);
            self.0.cancel_work();
        }
        Ok(self.view())
    }
}
impl Core {
    fn cancel_work(&self) {
        // Serialize cancellation with subprocess registration. In particular,
        // app exit cannot wait for the worker's next polling tick.
        let pids = self.active_pids.lock().unwrap();
        self.generation.fetch_add(1, Ordering::SeqCst);
        for pid in pids.iter() {
            #[cfg(unix)]
            unsafe {
                libc::kill(-(*pid as i32), libc::SIGKILL);
            }
        }
    }

    fn cancelled(&self, generation: u64) -> bool {
        self.shutdown.load(Ordering::SeqCst)
            || self.generation.load(Ordering::SeqCst) != generation
            || self.error.lock().unwrap().is_some()
    }
    fn write(&self, doc: &Document) -> bool {
        match self
            .path
            .as_ref()
            .ok_or_else(|| "Schedule storage unavailable".to_string())
            .and_then(|path| persist(path, doc))
        {
            Ok(()) => true,
            Err(e) => {
                *self.error.lock().unwrap() = Some(e);
                false
            }
        }
    }
    fn claim(&self, slot: DateTime<Utc>) -> Vec<Provider> {
        let mut doc = self.doc.lock().unwrap();
        if self.shutdown.load(Ordering::SeqCst)
            || self.error.lock().unwrap().is_some()
            || !doc.config.enabled
            || slot.timestamp() <= self.armed_after.load(Ordering::SeqCst)
        {
            return vec![];
        }
        let providers: Vec<_> = [
            (Provider::Claude, doc.config.claude),
            (Provider::Codex, doc.config.codex),
        ]
        .into_iter()
        .filter(|(p, selected)| {
            *selected
                && doc
                    .last_claimed
                    .get(p)
                    .is_none_or(|last| slot.timestamp() > *last)
        })
        .map(|(p, _)| p)
        .collect();
        if providers.is_empty() {
            return providers;
        }
        let mut updated = doc.clone();
        for provider in &providers {
            updated.last_claimed.insert(*provider, slot.timestamp());
            updated.history.insert(
                0,
                ActivationRun {
                    provider: *provider,
                    slot: format_slot(slot),
                    status: "pending".into(),
                    detail: "Claimed; no automatic retry".into(),
                },
            );
        }
        updated.history.truncate(HISTORY_LIMIT);
        if !self.write(&updated) {
            return vec![];
        } // persist BEFORE any subprocess
        *doc = updated;
        providers
    }
    fn mark_running(&self, provider: Provider, slot: DateTime<Utc>) -> bool {
        let mut doc = self.doc.lock().unwrap();
        if let Some(run) = doc
            .history
            .iter_mut()
            .find(|r| r.provider == provider && r.slot == format_slot(slot))
        {
            run.status = "running".into();
        }
        self.write(&doc)
    }
    fn finish(&self, provider: Provider, slot: DateTime<Utc>, result: Result<(), String>) {
        let mut doc = self.doc.lock().unwrap();
        if let Some(run) = doc
            .history
            .iter_mut()
            .find(|r| r.provider == provider && r.slot == format_slot(slot))
        {
            match result {
                Ok(()) => {
                    run.status = "success".into();
                    run.detail = "One minimal request completed".into();
                }
                Err(detail) => {
                    run.status = "failed".into();
                    run.detail = detail;
                }
            }
        }
        self.write(&doc);
    }
}
pub(crate) fn find_binary(name: &str) -> Option<PathBuf> {
    let mut dirs = vec![
        PathBuf::from("/opt/homebrew/bin"),
        PathBuf::from("/usr/local/bin"),
    ];
    if let Some(home) = dirs::home_dir() {
        dirs.push(home.join(".local/bin"));
    }
    if let Some(path) = std::env::var_os("PATH") {
        dirs.extend(std::env::split_paths(&path));
    }
    dirs.into_iter().map(|d| d.join(name)).find(|p| {
        #[cfg(unix)]
        {
            fs::metadata(p).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        }
        #[cfg(not(unix))]
        {
            p.is_file()
        }
    })
}
pub(crate) fn sanitized_command(binary: &Path, cwd: &Path) -> Command {
    let mut cmd = Command::new(binary);
    cmd.current_dir(cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    // Do not inherit alternate billing/provider credentials or nested-session detection.
    for (key, _) in std::env::vars_os() {
        let key_str = key.to_string_lossy();
        if key_str.starts_with("ANTHROPIC_")
            || key_str.starts_with("CLAUDE_CODE_")
            || key_str.starts_with("OPENAI_")
            || key_str.starts_with("CODEX_")
            || key_str == "CLAUDECODE"
            || key_str.starts_with("AWS_")
            || key_str.starts_with("GOOGLE_")
            || key_str == "MAP_SESSION_ID"
        {
            cmd.env_remove(key);
        }
    }
    // Preserve custom account directories, not provider/API environment overrides.
    for key in ["CODEX_HOME", "CLAUDE_CONFIG_DIR"] {
        if let Some(value) = std::env::var_os(key) {
            cmd.env(key, value);
        }
    }
    #[cfg(unix)]
    cmd.process_group(0);
    cmd
}
fn request_args(provider: Provider) -> Vec<&'static str> {
    match provider {
        Provider::Claude => vec![
            "-p",
            PROMPT,
            "--output-format",
            "json",
            "--no-session-persistence",
            "--max-turns",
            "1",
            "--permission-mode",
            "dontAsk",
            "--tools",
            "",
            "--disallowedTools",
            "mcp__*",
            "--strict-mcp-config",
            "--mcp-config",
            "{\"mcpServers\":{}}",
            "--settings",
            "{\"disableAllHooks\":true}",
            "--setting-sources",
            "",
            "--system-prompt",
            "Reply exactly OK. Do not use tools.",
        ],
        Provider::Codex => vec![
            "exec",
            "--json",
            "--ephemeral",
            "--skip-git-repo-check",
            "--ignore-user-config",
            "--ignore-rules",
            "--sandbox",
            "read-only",
            "-c",
            "approval_policy=\"never\"",
            "-c",
            "web_search=\"disabled\"",
            "--disable",
            "hooks",
            "--disable",
            "plugins",
            "--disable",
            "apps",
            "--disable",
            "shell_tool",
            "--disable",
            "unified_exec",
            "--disable",
            "multi_agent",
            "--disable",
            "browser_use",
            "--disable",
            "computer_use",
            "--disable",
            "image_generation",
            "--disable",
            "skill_mcp_dependency_install",
            "--disable",
            "memories",
            PROMPT,
        ],
    }
}
fn account_auth(provider: Provider, output: &[u8]) -> bool {
    match provider {
        Provider::Claude => serde_json::from_slice::<serde_json::Value>(output).is_ok_and(|v| {
            v["loggedIn"] == true
                && v["authMethod"] == "claude.ai"
                && v["apiProvider"] == "firstParty"
        }),
        Provider::Codex => String::from_utf8_lossy(output).trim() == "Logged in using ChatGPT",
    }
}
fn valid_response(provider: Provider, output: &[u8]) -> bool {
    match provider {
        Provider::Claude => serde_json::from_slice::<serde_json::Value>(output).is_ok_and(|v| {
            v["type"] == "result"
                && v["subtype"] == "success"
                && v["is_error"] == false
                && v["result"].as_str().is_some_and(|s| s.trim() == "OK")
        }),
        Provider::Codex => {
            let mut completed = false;
            let mut reply = false;
            for line in output.split(|b| *b == b'\n').filter(|l| !l.is_empty()) {
                let Ok(v) = serde_json::from_slice::<serde_json::Value>(line) else {
                    return false;
                };
                match v["type"].as_str() {
                    Some("error" | "turn.failed") => return false,
                    Some("turn.completed") => completed = true,
                    Some("item.completed") if v["item"]["type"] == "agent_message" => {
                        reply = v["item"]["text"].as_str().is_some_and(|s| s.trim() == "OK")
                    }
                    Some("item.started" | "item.completed")
                        if v["item"]["type"]
                            .as_str()
                            .is_some_and(|t| !["agent_message", "reasoning"].contains(&t)) =>
                    {
                        return false
                    }
                    _ => {}
                }
            }
            completed && reply
        }
    }
}
fn activate(provider: Provider, core: &Core, generation: u64) -> Result<(), String> {
    let binary = find_binary(provider.binary())
        .ok_or_else(|| format!("{} CLI not found in GUI PATH", provider.binary()))?;
    activate_with_binary(provider, &binary, core, generation)
}
fn activate_with_binary(
    provider: Provider,
    binary: &Path,
    core: &Core,
    generation: u64,
) -> Result<(), String> {
    let cwd = tempfile::tempdir().map_err(|_| "Cannot create isolated activation directory")?;
    let mut auth = sanitized_command(binary, cwd.path());
    match provider {
        Provider::Claude => {
            auth.args(["auth", "status", "--json"]);
        }
        Provider::Codex => {
            auth.args(["login", "status"]);
        }
    }
    let (stdout, stderr) = run_bounded(auth, core, generation, Duration::from_secs(20))?;
    // Codex login status currently writes to stderr. Never persist auth output.
    if !account_auth(provider, &stdout) && !account_auth(provider, &stderr) {
        return Err("Subscription login not confirmed; API/unknown auth refused".into());
    }
    let mut command = sanitized_command(binary, cwd.path());
    command.args(request_args(provider));
    let (stdout, _) = run_bounded(command, core, generation, Duration::from_secs(120))?;
    if valid_response(provider, &stdout) {
        Ok(())
    } else {
        Err("CLI did not return a successful OK result; not retried".into())
    }
}
fn drain(mut reader: impl Read) -> Vec<u8> {
    let mut output = Vec::new();
    let mut buffer = [0; 4096];
    while let Ok(n) = reader.read(&mut buffer) {
        if n == 0 {
            break;
        }
        let keep = n.min(OUTPUT_LIMIT.saturating_sub(output.len()));
        output.extend_from_slice(&buffer[..keep]);
    }
    output
}
fn kill_group(child: &mut std::process::Child) {
    #[cfg(unix)]
    unsafe {
        libc::kill(-(child.id() as i32), libc::SIGKILL);
    }
    let _ = child.kill();
    let _ = child.wait();
}
fn run_bounded(
    mut command: Command,
    core: &Core,
    generation: u64,
    timeout: Duration,
) -> Result<(Vec<u8>, Vec<u8>), String> {
    // Serialize process registration with stop() to close the spawn/exit race.
    let mut child = {
        let mut pids = core.active_pids.lock().unwrap();
        if core.cancelled(generation) {
            return Err("Cancelled after settings changed".into());
        }
        let child = command.spawn().map_err(|_| "CLI could not start")?;
        pids.push(child.id());
        child
    };
    let stdout = child.stdout.take().ok_or("Cannot capture CLI output")?;
    let stderr = child.stderr.take().ok_or("Cannot capture CLI error")?;
    let (send_out, receive_out) = std::sync::mpsc::channel();
    let (send_err, receive_err) = std::sync::mpsc::channel();
    thread::spawn(move || {
        let _ = send_out.send(drain(stdout));
    });
    thread::spawn(move || {
        let _ = send_err.send(drain(stderr));
    });
    let start = Instant::now();
    let result = loop {
        if core.cancelled(generation) {
            kill_group(&mut child);
            break Err("Cancelled after settings changed".into());
        }
        if start.elapsed() >= timeout {
            kill_group(&mut child);
            break Err("CLI timed out; not retried".into());
        }
        match child.try_wait() {
            Ok(Some(status)) => {
                // Also collect descendants holding pipes after their parent exits.
                #[cfg(unix)]
                unsafe {
                    libc::kill(-(child.id() as i32), libc::SIGKILL);
                }
                break if status.success() {
                    Ok(())
                } else {
                    Err("CLI exited unsuccessfully; not retried".into())
                };
            }
            Ok(None) => thread::sleep(Duration::from_millis(100)),
            Err(_) => {
                kill_group(&mut child);
                break Err("Cannot monitor CLI process".into());
            }
        }
    };
    core.active_pids
        .lock()
        .unwrap()
        .retain(|pid| *pid != child.id());
    // Never hang the scheduler on a detached descendant retaining a pipe.
    let stdout = receive_out
        .recv_timeout(Duration::from_secs(1))
        .map_err(|_| "CLI output stream did not close")?;
    let stderr = receive_err
        .recv_timeout(Duration::from_secs(1))
        .map_err(|_| "CLI error stream did not close")?;
    result.map(|_| (stdout, stderr))
}
#[tauri::command]
pub fn get_activation_schedule(state: tauri::State<'_, ActivationScheduler>) -> ActivationView {
    state.view()
}
#[tauri::command]
pub fn save_activation_schedule(
    config: ActivationConfig,
    state: tauri::State<'_, ActivationScheduler>,
) -> Result<ActivationView, String> {
    state.save(config)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn time(s: &str) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(s).unwrap().with_timezone(&Utc)
    }
    #[test]
    fn kst_slots_not_host_timezone() {
        for hour in HOURS {
            assert!(slot_at(time(&format!("2026-10-01T{hour:02}:00:45+09:00"))).is_some());
        }
        assert!(slot_at(time("2026-10-01T06:01:00+09:00")).is_none());
        assert!(slot_at(time("2026-10-01T05:59:59+09:00")).is_none());
        assert_eq!(
            format_slot(next_slot(time("2026-10-01T21:00:00+09:00"))),
            "2026-10-02T06:00:00+09:00"
        );
    }
    #[test]
    fn default_off_no_catchup_claim_persisted() {
        let dir = tempfile::tempdir().unwrap();
        let scheduler = ActivationScheduler::new(dir.path());
        let slot = time("2026-10-02T06:00:00+09:00");
        scheduler
            .0
            .armed_after
            .store(slot.timestamp() - 1, Ordering::SeqCst);
        assert!(scheduler.0.claim(slot).is_empty());
        {
            scheduler.0.doc.lock().unwrap().config.enabled = true;
        }
        assert_eq!(scheduler.0.claim(slot).len(), 2);
        assert!(scheduler.0.claim(slot).is_empty());
        assert!(scheduler
            .0
            .claim(slot - ChronoDuration::hours(5))
            .is_empty());
        drop(scheduler);
        let restarted = ActivationScheduler::new(dir.path());
        restarted
            .0
            .armed_after
            .store(slot.timestamp() - 1, Ordering::SeqCst);
        assert!(restarted.0.claim(slot).is_empty());
        assert!(restarted
            .view()
            .history
            .iter()
            .all(|r| r.status == "interrupted"));
    }
    #[test]
    fn enable_skips_current_slot_and_requires_selection() {
        let dir = tempfile::tempdir().unwrap();
        let scheduler = ActivationScheduler::new(dir.path());
        assert!(scheduler
            .save(ActivationConfig {
                enabled: true,
                claude: false,
                codex: false
            })
            .is_err());
        let slot = time("2026-10-01T06:00:00+09:00");
        scheduler
            .0
            .armed_after
            .store(slot.timestamp(), Ordering::SeqCst);
        scheduler.0.doc.lock().unwrap().config.enabled = true;
        assert!(scheduler.0.claim(slot).is_empty());
    }
    #[test]
    fn lock_and_corruption_fail_closed() {
        let dir = tempfile::tempdir().unwrap();
        let first = ActivationScheduler::new(dir.path());
        let second = ActivationScheduler::new(dir.path());
        assert!(!second.view().available);
        assert!(second.save(ActivationConfig::default()).is_err());
        drop(first);
        drop(second);
        fs::write(dir.path().join("activation.json"), "invalid").unwrap();
        assert!(!ActivationScheduler::new(dir.path()).view().available);
    }
    #[test]
    fn auth_and_success_require_known_structured_result() {
        assert!(account_auth(
            Provider::Claude,
            br#"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}"#
        ));
        assert!(!account_auth(
            Provider::Claude,
            br#"{"loggedIn":true,"authMethod":"api_key"}"#
        ));
        assert!(account_auth(Provider::Codex, b"Logged in using ChatGPT\n"));
        assert!(!account_auth(
            Provider::Codex,
            b"Logged in using an API key"
        ));
        assert!(valid_response(
            Provider::Claude,
            br#"{"type":"result","subtype":"success","is_error":false,"result":"OK"}"#
        ));
        assert!(!valid_response(
            Provider::Claude,
            br#"{"result":"OK","is_error":true}"#
        ));
        let jsonl = b"{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"OK\"}}\n{\"type\":\"turn.completed\"}\n";
        assert!(valid_response(Provider::Codex, jsonl));
        assert!(!valid_response(
            Provider::Codex,
            b"{\"type\":\"turn.completed\"}"
        ));
        assert!(!valid_response(
            Provider::Codex,
            &[jsonl.as_slice(), b"{\"type\":\"turn.failed\"}"].concat()
        ));
    }
    #[test]
    fn profiles_disable_tools_and_bypass() {
        for provider in [Provider::Claude, Provider::Codex] {
            let args = request_args(provider);
            assert!(args.contains(&PROMPT));
            assert!(!args
                .iter()
                .any(|a| a.contains("bypassPermissions") || a.contains("dangerously")));
        }
        assert!(request_args(Provider::Claude)
            .windows(2)
            .any(|a| a == ["--tools", ""]));
        assert!(request_args(Provider::Codex).contains(&"--ignore-user-config"));
    }
    #[cfg(unix)]
    #[test]
    fn stub_process_failure_timeout_cancellation_and_bounded_output() {
        let dir = tempfile::tempdir().unwrap();
        let scheduler = ActivationScheduler::new(dir.path());
        let cmd = |script: &str| {
            let mut c = sanitized_command(Path::new("/bin/sh"), dir.path());
            c.args(["-c", script]);
            c
        };
        assert!(run_bounded(
            cmd("echo partial; exit 7"),
            &scheduler.0,
            0,
            Duration::from_secs(1)
        )
        .is_err());
        assert!(run_bounded(
            cmd("sleep 30 & wait"),
            &scheduler.0,
            0,
            Duration::from_millis(100)
        )
        .is_err());
        assert!(run_bounded(cmd("echo OK"), &scheduler.0, 1, Duration::from_secs(1)).is_err());
        let (out, _) = run_bounded(
            cmd("yes x | head -c 100000"),
            &scheduler.0,
            0,
            Duration::from_secs(2),
        )
        .unwrap();
        assert_eq!(out.len(), OUTPUT_LIMIT);
    }
    #[cfg(unix)]
    #[test]
    fn full_activation_uses_only_stub_and_refuses_api_auth() {
        let dir = tempfile::tempdir().unwrap();
        let scheduler = ActivationScheduler::new(dir.path());
        for provider in [Provider::Claude, Provider::Codex] {
            let stub = dir.path().join(provider.binary());
            let log = dir.path().join(format!("{}.calls", provider.binary()));
            let auth = match provider { Provider::Claude => "echo '{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"apiProvider\":\"firstParty\"}'", Provider::Codex => "echo 'Logged in using ChatGPT' >&2" };
            let response = match provider { Provider::Claude => "echo '{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"OK\"}'", Provider::Codex => "printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"OK\"}}' '{\"type\":\"turn.completed\"}'" };
            let script = format!("#!/bin/sh\necho call >> '{}'\nif [ \"$1\" = auth ] || [ \"$1\" = login ]; then {}; else {}; fi\n", log.display(), auth, response);
            fs::write(&stub, &script).unwrap();
            fs::set_permissions(&stub, fs::Permissions::from_mode(0o700)).unwrap();
            activate_with_binary(provider, &stub, &scheduler.0, 0).unwrap();
            assert_eq!(fs::read_to_string(&log).unwrap().lines().count(), 2);
            fs::write(&stub, script.replace(auth, "echo '{}'")).unwrap();
            assert!(activate_with_binary(provider, &stub, &scheduler.0, 0).is_err());
            assert_eq!(fs::read_to_string(&log).unwrap().lines().count(), 3); // auth only, no request
        }
    }
    #[cfg(unix)]
    #[test]
    fn off_cancels_an_inflight_stub_even_when_storage_fails() {
        let dir = tempfile::tempdir().unwrap();
        let scheduler = ActivationScheduler::new(dir.path());
        let marker = dir.path().join("started");
        let mut command = sanitized_command(Path::new("/bin/sh"), dir.path());
        command.args([
            "-c",
            &format!("touch '{}'; sleep 30 & wait", marker.display()),
        ]);
        let core = scheduler.0.clone();
        let running = thread::spawn(move || run_bounded(command, &core, 0, Duration::from_secs(5)));
        for _ in 0..100 {
            if marker.exists() {
                break;
            }
            thread::sleep(Duration::from_millis(10));
        }
        assert!(marker.exists());
        fs::remove_file(dir.path().join("activation.json")).unwrap();
        fs::create_dir(dir.path().join("activation.json")).unwrap(); // force persistence error
        assert!(scheduler.save(ActivationConfig::default()).is_err());
        assert!(running.join().unwrap().is_err());
        assert!(!scheduler.view().config.enabled);
        assert!(!scheduler.view().available);
    }
}
