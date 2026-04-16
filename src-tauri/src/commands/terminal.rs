use portable_pty::{native_pty_system, CommandBuilder, MasterPty, PtySize};
use serde::Serialize;
use std::collections::{HashMap, VecDeque};
use std::io::{Read, Write};
use std::sync::{Arc, Mutex};
use tauri::ipc::Channel;
use uuid::Uuid;

const MAX_BUFFER_CHUNKS: usize = 1000;

#[derive(Clone, Serialize)]
#[serde(tag = "type")]
pub enum TerminalOutput {
    Data { data: String },
    Exit { code: Option<u32> },
}

#[derive(Clone, Serialize)]
pub struct TerminalInfo {
    pub id: String,
    pub is_connected: bool,
}

struct PtySession {
    #[allow(dead_code)]
    master: Box<dyn MasterPty + Send>,
    writer: Box<dyn Write + Send>,
    reader_abort: Arc<std::sync::atomic::AtomicBool>,
    output_buffer: Arc<Mutex<VecDeque<String>>>,
    is_connected: Arc<std::sync::atomic::AtomicBool>,
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

/// Spawn a reader task that streams PTY output to the channel and buffer.
fn spawn_reader(
    mut reader: Box<dyn Read + Send>,
    on_output: Channel<TerminalOutput>,
    abort_flag: Arc<std::sync::atomic::AtomicBool>,
    output_buffer: Arc<Mutex<VecDeque<String>>>,
    is_connected: Arc<std::sync::atomic::AtomicBool>,
) {
    is_connected.store(true, std::sync::atomic::Ordering::Relaxed);
    tokio::task::spawn_blocking(move || {
        let mut buf = [0u8; 4096];
        let mut leftover = Vec::new();
        loop {
            if abort_flag.load(std::sync::atomic::Ordering::Relaxed) {
                break;
            }
            match reader.read(&mut buf) {
                Ok(0) => {
                    let _ = on_output.send(TerminalOutput::Exit { code: None });
                    break;
                }
                Ok(n) => {
                    let mut combined = std::mem::take(&mut leftover);
                    combined.extend_from_slice(&buf[..n]);

                    let valid_len = find_utf8_boundary(&combined);
                    if valid_len < combined.len() {
                        leftover = combined[valid_len..].to_vec();
                    }

                    let data = String::from_utf8_lossy(&combined[..valid_len]).to_string();
                    if !data.is_empty() {
                        // Store in buffer for reconnection replay
                        if let Ok(mut buf) = output_buffer.lock() {
                            buf.push_back(data.clone());
                            while buf.len() > MAX_BUFFER_CHUNKS {
                                buf.pop_front();
                            }
                        }

                        if on_output.send(TerminalOutput::Data { data }).is_err() {
                            // Channel disconnected (webview reloaded)
                            is_connected.store(false, std::sync::atomic::Ordering::Relaxed);
                            // Keep reading into buffer instead of breaking
                            drain_to_buffer_only(
                                reader,
                                leftover,
                                abort_flag,
                                output_buffer,
                            );
                            return;
                        }
                    }
                }
                Err(_) => {
                    let _ = on_output.send(TerminalOutput::Exit { code: None });
                    break;
                }
            }
        }
        is_connected.store(false, std::sync::atomic::Ordering::Relaxed);
    });
}

/// When channel disconnects, keep reading PTY output into the buffer
/// so it can be replayed on reconnection.
fn drain_to_buffer_only(
    mut reader: Box<dyn Read + Send>,
    mut leftover: Vec<u8>,
    abort_flag: Arc<std::sync::atomic::AtomicBool>,
    output_buffer: Arc<Mutex<VecDeque<String>>>,
) {
    let mut buf = [0u8; 4096];
    loop {
        if abort_flag.load(std::sync::atomic::Ordering::Relaxed) {
            break;
        }
        match reader.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                let mut combined = std::mem::take(&mut leftover);
                combined.extend_from_slice(&buf[..n]);

                let valid_len = find_utf8_boundary(&combined);
                if valid_len < combined.len() {
                    leftover = combined[valid_len..].to_vec();
                }

                let data = String::from_utf8_lossy(&combined[..valid_len]).to_string();
                if !data.is_empty() {
                    if let Ok(mut b) = output_buffer.lock() {
                        b.push_back(data);
                        while b.len() > MAX_BUFFER_CHUNKS {
                            b.pop_front();
                        }
                    }
                }
            }
            Err(_) => break,
        }
    }
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
    cmd.arg("-l");

    if let Some(ref dir) = cwd {
        cmd.cwd(dir);
    }

    pair.slave
        .spawn_command(cmd)
        .map_err(|e| format!("셸 실행 실패: {}", e))?;

    drop(pair.slave);

    let reader = pair
        .master
        .try_clone_reader()
        .map_err(|e| format!("Reader 생성 실패: {}", e))?;

    let mut writer = pair
        .master
        .take_writer()
        .map_err(|e| format!("Writer 생성 실패: {}", e))?;

    if let Some(ref cmd_str) = initial_command {
        let cmd_with_newline = format!("{}\n", cmd_str);
        let _ = writer.write_all(cmd_with_newline.as_bytes());
        let _ = writer.flush();
    }

    let abort_flag = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let output_buffer = Arc::new(Mutex::new(VecDeque::new()));
    let is_connected = Arc::new(std::sync::atomic::AtomicBool::new(false));

    spawn_reader(
        reader,
        on_output,
        abort_flag.clone(),
        output_buffer.clone(),
        is_connected.clone(),
    );

    let session = PtySession {
        master: pair.master,
        writer: Box::new(writer),
        reader_abort: abort_flag,
        output_buffer,
        is_connected,
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

/// List all active PTY sessions (for reconnection after reload).
#[tauri::command]
pub async fn terminal_list(
    state: tauri::State<'_, TerminalManager>,
) -> Result<Vec<TerminalInfo>, String> {
    let sessions = state
        .sessions
        .lock()
        .map_err(|e| format!("Lock 실패: {}", e))?;

    let info: Vec<TerminalInfo> = sessions
        .iter()
        .map(|(id, session)| TerminalInfo {
            id: id.clone(),
            is_connected: session
                .is_connected
                .load(std::sync::atomic::Ordering::Relaxed),
        })
        .collect();

    Ok(info)
}

/// Reconnect to an existing PTY session with a new output channel.
/// Replays buffered output, then streams live output.
#[tauri::command]
pub async fn terminal_reconnect(
    state: tauri::State<'_, TerminalManager>,
    terminal_id: String,
    on_output: Channel<TerminalOutput>,
) -> Result<String, String> {
    let sessions = state
        .sessions
        .lock()
        .map_err(|e| format!("Lock 실패: {}", e))?;

    let session = sessions
        .get(&terminal_id)
        .ok_or_else(|| format!("터미널 {} 없음", terminal_id))?;

    // Replay buffered output
    if let Ok(buf) = session.output_buffer.lock() {
        for chunk in buf.iter() {
            let _ = on_output.send(TerminalOutput::Data {
                data: chunk.clone(),
            });
        }
    }

    // Try to get a new reader from the master
    let new_reader = session
        .master
        .try_clone_reader()
        .map_err(|e| format!("Reader 재생성 실패: {}", e))?;

    // Spawn a new reader task
    spawn_reader(
        new_reader,
        on_output,
        session.reader_abort.clone(),
        session.output_buffer.clone(),
        session.is_connected.clone(),
    );

    Ok(terminal_id)
}

/// Find the largest prefix of `bytes` that is valid UTF-8.
fn find_utf8_boundary(bytes: &[u8]) -> usize {
    match std::str::from_utf8(bytes) {
        Ok(_) => bytes.len(),
        Err(e) => e.valid_up_to(),
    }
}
