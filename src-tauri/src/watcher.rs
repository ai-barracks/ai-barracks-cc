use notify::{Config, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use std::path::PathBuf;
use std::sync::mpsc;
use std::thread;
use tauri::{AppHandle, Emitter};

pub fn start_watcher(app: AppHandle) {
    thread::spawn(move || {
        let registry_path = dirs::home_dir()
            .unwrap_or_default()
            .join(".aib")
            .join("barracks.json");

        // Read barracks.json to get all barrack paths
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

        // Watch barracks.json itself
        if let Err(e) = watcher.watch(&registry_path, RecursiveMode::NonRecursive) {
            eprintln!("Failed to watch barracks.json: {}", e);
        }

        // Watch each barrack's sessions/ directory and key files
        for path in &paths {
            let sessions_dir = PathBuf::from(path).join("sessions");
            if sessions_dir.exists() {
                let _ = watcher.watch(&sessions_dir, RecursiveMode::NonRecursive);
            }
            // Watch SOUL.md, RULES.md, etc.
            for file in &["SOUL.md", "RULES.md", "GROWTH.md", "agent.yaml"] {
                let file_path = PathBuf::from(path).join(file);
                if file_path.exists() {
                    let _ = watcher.watch(&file_path, RecursiveMode::NonRecursive);
                }
            }
        }

        // Process events
        loop {
            match rx.recv() {
                Ok(event) => {
                    if matches!(
                        event.kind,
                        EventKind::Modify(_) | EventKind::Create(_) | EventKind::Remove(_)
                    ) {
                        // Emit a generic "file-changed" event to frontend
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
