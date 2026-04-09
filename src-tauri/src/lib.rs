mod commands;
mod watcher;

use commands::{barracks, files, search, sessions, sync, wiki};

/// Find the `aib` binary path — GUI apps don't inherit shell PATH
pub fn aib_bin() -> String {
    let candidates = [
        "/opt/homebrew/bin/aib",
        "/usr/local/bin/aib",
    ];
    for path in candidates {
        if std::path::Path::new(path).exists() {
            return path.to_string();
        }
    }
    // Fallback: hope it's in PATH
    "aib".to_string()
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .invoke_handler(tauri::generate_handler![
            barracks::get_barracks,
            barracks::get_cli_version,
            files::get_barrack_files,
            files::read_file,
            files::write_file,
            files::get_rules,
            files::save_rules,
            sessions::get_sessions,
            sessions::get_session_detail,
            wiki::get_wiki_index,
            wiki::get_wiki_topic,
            sync::sync_barrack,
            sync::sync_all_barracks,
            sync::create_barrack,
            sync::launch_session,
            sync::continue_session,
            sync::refresh_barracks,
            search::search_all,
        ])
        .setup(|app| {
            watcher::start_watcher(app.handle().clone());
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
