use notify::{Config, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use std::path::PathBuf;
use std::sync::mpsc;
use std::thread;
use std::time::Duration;
use tauri::{AppHandle, Emitter};
use tauri_plugin_notification::NotificationExt;

pub fn start_watcher(app: AppHandle) {
    thread::spawn(move || {
        let registry_path = dirs::home_dir()
            .unwrap_or_default()
            .join(".aib")
            .join("barracks.json");

        let paths = read_barrack_paths(&registry_path);

        let (tx, rx) = mpsc::channel();

        let mut watcher = match RecommendedWatcher::new(
            move |res: Result<notify::Event, notify::Error>| {
                if let Ok(event) = res {
                    let _ = tx.send(event);
                }
            },
            Config::default(),
        ) {
            Ok(w) => w,
            Err(e) => {
                eprintln!("Failed to create watcher: {}", e);
                return;
            }
        };

        if let Err(e) = watcher.watch(&registry_path, RecursiveMode::NonRecursive) {
            eprintln!("Failed to watch barracks.json: {}", e);
        }

        for path in &paths {
            let sessions_dir = PathBuf::from(path).join("sessions");
            if sessions_dir.exists() {
                let _ = watcher.watch(&sessions_dir, RecursiveMode::NonRecursive);
            }
            for file in &["SOUL.md", "RULES.md", "GROWTH.md", "agent.yaml"] {
                let file_path = PathBuf::from(path).join(file);
                if file_path.exists() {
                    let _ = watcher.watch(&file_path, RecursiveMode::NonRecursive);
                }
            }
        }

        loop {
            match rx.recv() {
                Ok(event) => {
                    if matches!(
                        event.kind,
                        EventKind::Modify(_) | EventKind::Create(_) | EventKind::Remove(_)
                    ) {
                        let changed_path = event
                            .paths
                            .first()
                            .map(|p| p.to_string_lossy().to_string())
                            .unwrap_or_default();
                        let _ = app.emit("file-changed", changed_path);
                    }
                }
                Err(_) => break,
            }
        }
    });
}

/// Periodic checks every 30 seconds for stale sessions, sync needs, etc.
pub fn start_periodic_checks(app: AppHandle) {
    thread::spawn(move || {
        // Wait 10 seconds before first check to let app initialize
        thread::sleep(Duration::from_secs(10));

        loop {
            check_stale_sessions(&app);
            check_sync_needed(&app);

            thread::sleep(Duration::from_secs(30));
        }
    });
}

fn check_stale_sessions(app: &AppHandle) {
    let registry_path = dirs::home_dir()
        .unwrap_or_default()
        .join(".aib")
        .join("barracks.json");

    let paths = read_barrack_paths(&registry_path);

    for barrack_path in &paths {
        let sessions_md = PathBuf::from(barrack_path).join("SESSIONS.md");
        let content = match std::fs::read_to_string(&sessions_md) {
            Ok(c) => c,
            Err(_) => continue,
        };

        // Parse active sessions from SESSIONS.md table
        for line in content.lines() {
            let trimmed = line.trim();
            if !trimmed.starts_with('|') || trimmed.contains("---") || trimmed.contains("Session") {
                continue;
            }
            let cols: Vec<&str> = trimmed.split('|').collect();
            if cols.len() < 5 {
                continue;
            }
            let session_id = cols[1].trim();
            if session_id.is_empty() {
                continue;
            }

            // Check session file modification time
            let session_file = PathBuf::from(barrack_path)
                .join("sessions")
                .join(format!("{}.md", session_id));
            if let Ok(metadata) = std::fs::metadata(&session_file) {
                if let Ok(modified) = metadata.modified() {
                    let elapsed = modified.elapsed().unwrap_or_default();
                    if elapsed > Duration::from_secs(7200) {
                        // 2 hours
                        let barrack_name = PathBuf::from(barrack_path)
                            .file_name()
                            .map(|n| n.to_string_lossy().to_string())
                            .unwrap_or_default();
                        let hours = elapsed.as_secs() / 3600;
                        let _ = app
                            .notification()
                            .builder()
                            .title("Stale Agent Detected")
                            .body(format!(
                                "{} in {} — {}h inactive",
                                session_id, barrack_name, hours
                            ))
                            .show();
                        break; // One notification per barrack per cycle
                    }
                }
            }
        }
    }
}

fn check_sync_needed(app: &AppHandle) {
    // Get CLI version
    let cli_output = std::process::Command::new(crate::aib_bin())
        .arg("version")
        .output();
    let cli_version = match cli_output {
        Ok(out) => {
            let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
            s.strip_prefix("aib v").unwrap_or(&s).to_string()
        }
        Err(_) => return,
    };

    let registry_path = dirs::home_dir()
        .unwrap_or_default()
        .join(".aib")
        .join("barracks.json");

    let paths = read_barrack_paths(&registry_path);
    let mut outdated_count = 0;

    for barrack_path in &paths {
        let yaml_path = PathBuf::from(barrack_path).join("agent.yaml");
        if let Ok(content) = std::fs::read_to_string(&yaml_path) {
            for line in content.lines() {
                if let Some(ver) = line.strip_prefix("aib_version:") {
                    let ver = ver.trim();
                    if ver != cli_version {
                        outdated_count += 1;
                    }
                    break;
                }
            }
        }
    }

    if outdated_count > 0 {
        let _ = app
            .notification()
            .builder()
            .title("Sync Required")
            .body(format!(
                "{} barrack(s) need sync to v{}",
                outdated_count, cli_version
            ))
            .show();
    }
}

fn read_barrack_paths(registry_path: &PathBuf) -> Vec<String> {
    let content = match std::fs::read_to_string(registry_path) {
        Ok(c) => c,
        Err(_) => return Vec::new(),
    };
    let entries: Vec<serde_json::Value> = match serde_json::from_str(&content) {
        Ok(e) => e,
        Err(_) => return Vec::new(),
    };
    entries
        .iter()
        .filter_map(|e| e["path"].as_str().map(String::from))
        .collect()
}
