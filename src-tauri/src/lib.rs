mod commands;
mod watcher;

use commands::{barracks, files, git, search, sessions, sync, terminal, wiki};
use tauri::{
    menu::{MenuBuilder, MenuItemBuilder},
    tray::TrayIconBuilder,
    Manager,
};

/// Find the `aib` binary path — GUI apps don't inherit shell PATH
pub fn aib_bin() -> String {
    let candidates = ["/opt/homebrew/bin/aib", "/usr/local/bin/aib"];
    for path in candidates {
        if std::path::Path::new(path).exists() {
            return path.to_string();
        }
    }
    "aib".to_string()
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_notification::init())
        .manage(terminal::TerminalManager::new())
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
            sync::remove_barrack,
            sync::create_barrack,
            sync::launch_session,
            sync::continue_session,
            sync::refresh_barracks,
            search::search_all,
            git::get_git_status,
            git::get_git_log,
            git::git_commit,
            git::git_push,
            sync::get_launch_command,
            sync::get_continue_command,
            terminal::terminal_create,
            terminal::terminal_write,
            terminal::terminal_resize,
            terminal::terminal_close,
            terminal::terminal_close_all,
            terminal::terminal_list,
            terminal::terminal_reconnect,
        ])
        .setup(|app| {
            // --- System Tray ---
            let show = MenuItemBuilder::with_id("show", "Show CommandCenter").build(app)?;
            let quit = MenuItemBuilder::with_id("quit", "Quit").build(app)?;
            let menu = MenuBuilder::new(app).items(&[&show, &quit]).build()?;

            let icon = tauri::image::Image::from_bytes(include_bytes!("../icons/32x32.png"))?;

            let _tray = TrayIconBuilder::new()
                .icon(icon)
                .menu(&menu)
                .tooltip("AI Barracks CommandCenter")
                .on_menu_event(move |app, event| match event.id().as_ref() {
                    "show" => {
                        if let Some(w) = app.get_webview_window("main") {
                            let _ = w.show();
                            let _ = w.set_focus();
                        }
                    }
                    "quit" => {
                        let manager = app.state::<terminal::TerminalManager>();
                        manager.close_all_sync();
                        app.exit(0);
                    }
                    _ => {}
                })
                .build(app)?;

            // Hide to tray instead of quitting when window is closed
            let app_handle = app.handle().clone();
            if let Some(window) = app.get_webview_window("main") {
                window.on_window_event(move |event| {
                    if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                        api.prevent_close();
                        if let Some(w) = app_handle.get_webview_window("main") {
                            let _ = w.hide();
                        }
                    }
                });
            }

            // --- File Watcher + Periodic Checks ---
            watcher::start_watcher(app.handle().clone());
            watcher::start_periodic_checks(app.handle().clone());

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
