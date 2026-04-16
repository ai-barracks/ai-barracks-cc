use portable_pty::{native_pty_system, CommandBuilder, MasterPty, PtySize};
use serde::Serialize;
use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::{Arc, Mutex};
use tauri::ipc::Channel;
use uuid::Uuid;

#[derive(Clone, Serialize)]
#[serde(tag = "type")]
pub enum TerminalOutput {
    Data { data: String },
    Exit { code: Option<u32> },
}

struct PtySession {
    #[allow(dead_code)]
    master: Box<dyn MasterPty + Send>,
    writer: Box<dyn Write + Send>,
    reader_abort: Arc<std::sync::atomic::AtomicBool>,
}

pub struct TerminalManager {
    sessions: Arc<Mutex<HashMap<String, PtySession>>>,
}

impl TerminalManager {
    pub fn new() -> Self {
        Self {
            sessions: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub fn close_all_sync(&self) {
        let mut sessions = self.sessions.lock().unwrap();
        for (_, session) in sessions.drain() {
            session
                .reader_abort
                .store(true, std::sync::atomic::Ordering::Relaxed);
            drop(session);
        }
    }
}

fn default_shell() -> String {
    std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".to_string())
}

#[tauri::command]
pub async fn terminal_create(
    state: tauri::State<'_, TerminalManager>,
    on_output: Channel<TerminalOutput>,
    cwd: Option<String>,
    initial_command: Option<String>,
    cols: Option<u16>,
    rows: Option<u16>,
) -> Result<String, String> {
    let terminal_id = Uuid::new_v4().to_string();

    let pty_system = native_pty_system();
    let size = PtySize {
        rows: rows.unwrap_or(24),
        cols: cols.unwrap_or(80),
        pixel_width: 0,
        pixel_height: 0,
    };

    let pair = pty_system
        .openpty(size)
        .map_err(|e| format!("PTY 생성 실패: {}", e))?;

    let shell = default_shell();
    let mut cmd = CommandBuilder::new(&shell);
    cmd.arg("-l"); // login shell for proper env

    if let Some(ref dir) = cwd {
        cmd.cwd(dir);
    }

    pair.slave
        .spawn_command(cmd)
        .map_err(|e| format!("셸 실행 실패: {}", e))?;

    // Drop slave — we only need the master side
    drop(pair.slave);

    let mut reader = pair
        .master
        .try_clone_reader()
        .map_err(|e| format!("Reader 생성 실패: {}", e))?;

    let mut writer = pair
        .master
        .take_writer()
        .map_err(|e| format!("Writer 생성 실패: {}", e))?;

    // Write initial command if provided (after shell init)
    if let Some(ref cmd_str) = initial_command {
        let cmd_with_newline = format!("{}\n", cmd_str);
        let _ = writer.write_all(cmd_with_newline.as_bytes());
        let _ = writer.flush();
    }

    let abort_flag = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let abort_clone = abort_flag.clone();

    // Spawn blocking reader task with UTF-8 boundary handling
    tokio::task::spawn_blocking(move || {
        let mut buf = [0u8; 4096];
        let mut leftover = Vec::new(); // partial UTF-8 bytes from previous read
        loop {
            if abort_clone.load(std::sync::atomic::Ordering::Relaxed) {
                break;
            }
            match reader.read(&mut buf) {
                Ok(0) => {
                    let _ = on_output.send(TerminalOutput::Exit { code: None });
                    break;
                }
                Ok(n) => {
                    // Prepend leftover bytes from previous read
                    let mut combined = std::mem::take(&mut leftover);
                    combined.extend_from_slice(&buf[..n]);

                    // Find the last valid UTF-8 boundary
                    let valid_len = find_utf8_boundary(&combined);
                    if valid_len < combined.len() {
                        leftover = combined[valid_len..].to_vec();
                    }

                    let data = String::from_utf8_lossy(&combined[..valid_len]).to_string();
                    if !data.is_empty() {
                        if on_output.send(TerminalOutput::Data { data }).is_err() {
                            break;
                        }
                    }
                }
                Err(_) => {
                    let _ = on_output.send(TerminalOutput::Exit { code: None });
                    break;
                }
            }
        }
    });

    let session = PtySession {
        master: pair.master,
        writer: Box::new(writer),
        reader_abort: abort_flag,
    };

    state
        .sessions
        .lock()
        .map_err(|e| format!("Lock 실패: {}", e))?
        .insert(terminal_id.clone(), session);

    Ok(terminal_id)
}

#[tauri::command]
pub async fn terminal_write(
    state: tauri::State<'_, TerminalManager>,
    terminal_id: String,
    data: String,
) -> Result<(), String> {
    let mut sessions = state
        .sessions
        .lock()
        .map_err(|e| format!("Lock 실패: {}", e))?;

    let session = sessions
        .get_mut(&terminal_id)
        .ok_or_else(|| format!("터미널 {} 없음", terminal_id))?;

    session
        .writer
        .write_all(data.as_bytes())
        .map_err(|e| format!("Write 실패: {}", e))?;

    session
        .writer
        .flush()
        .map_err(|e| format!("Flush 실패: {}", e))?;

    Ok(())
}

#[tauri::command]
pub async fn terminal_resize(
    state: tauri::State<'_, TerminalManager>,
    terminal_id: String,
    cols: u16,
    rows: u16,
) -> Result<(), String> {
    let sessions = state
        .sessions
        .lock()
        .map_err(|e| format!("Lock 실패: {}", e))?;

    let session = sessions
        .get(&terminal_id)
        .ok_or_else(|| format!("터미널 {} 없음", terminal_id))?;

    session
        .master
        .resize(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })
        .map_err(|e| format!("Resize 실패: {}", e))?;

    Ok(())
}

#[tauri::command]
pub async fn terminal_close(
    state: tauri::State<'_, TerminalManager>,
    terminal_id: String,
) -> Result<(), String> {
    let mut sessions = state
        .sessions
        .lock()
        .map_err(|e| format!("Lock 실패: {}", e))?;

    if let Some(session) = sessions.remove(&terminal_id) {
        session
            .reader_abort
            .store(true, std::sync::atomic::Ordering::Relaxed);
        drop(session);
    }

    Ok(())
}

#[tauri::command]
pub async fn terminal_close_all(
    state: tauri::State<'_, TerminalManager>,
) -> Result<(), String> {
    let mut sessions = state
        .sessions
        .lock()
        .map_err(|e| format!("Lock 실패: {}", e))?;

    for (_, session) in sessions.drain() {
        session
            .reader_abort
            .store(true, std::sync::atomic::Ordering::Relaxed);
        drop(session);
    }

    Ok(())
}

/// Find the largest prefix of `bytes` that is valid UTF-8.
/// If the tail contains an incomplete multi-byte sequence, exclude it.
fn find_utf8_boundary(bytes: &[u8]) -> usize {
    match std::str::from_utf8(bytes) {
        Ok(_) => bytes.len(),
        Err(e) => e.valid_up_to(),
    }
}
