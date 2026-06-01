use super::scrollback::ScrollbackStore;
use portable_pty::{native_pty_system, CommandBuilder, MasterPty, PtySize};
use serde::Serialize;
use std::collections::{HashMap, VecDeque};
use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tauri::ipc::Channel;
use uuid::Uuid;

const MAX_BUFFER_CHUNKS: usize = 1000;

/// How often the per-session debounce task flushes the ring to disk when dirty.
const SCROLLBACK_FLUSH_INTERVAL: Duration = Duration::from_secs(1);

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
    reader_abort: Arc<AtomicBool>,
    output_buffer: Arc<Mutex<VecDeque<String>>>,
    is_connected: Arc<AtomicBool>,
    /// Everything needed to flush this session's scrollback to disk.
    scrollback: ScrollbackHandle,
}

/// Bundles the state a flush needs: the disk store, this session's id/cwd, the
/// shared ring, and a dirty flag set by the reader and cleared by the flush.
#[derive(Clone)]
struct ScrollbackHandle {
    store: Arc<ScrollbackStore>,
    pty_id: String,
    cwd: Option<String>,
    buffer: Arc<Mutex<VecDeque<String>>>,
    dirty: Arc<AtomicBool>,
}

impl ScrollbackHandle {
    /// Serialize the current ring (concatenation of UTF-8 chunks, order
    /// preserved -> valid UTF-8) and atomically rewrite it to disk, but only if
    /// the dirty flag is set. Clears the dirty flag on a successful flush.
    /// Safe to call from any thread; never panics on I/O failure.
    fn flush_if_dirty(&self) {
        if !self.dirty.swap(false, Ordering::AcqRel) {
            return;
        }
        if !self.store.is_ready() {
            return;
        }
        let bytes = match self.buffer.lock() {
            Ok(buf) => {
                let mut out = Vec::new();
                for chunk in buf.iter() {
                    out.extend_from_slice(chunk.as_bytes());
                }
                out
            }
            Err(_) => {
                // Lock poisoned: re-mark dirty so a later flush can retry.
                self.dirty.store(true, Ordering::Release);
                return;
            }
        };
        if let Err(e) = self
            .store
            .save(&self.pty_id, &bytes, self.cwd.clone(), None)
        {
            // Re-mark dirty so we retry on the next tick; do not crash.
            self.dirty.store(true, Ordering::Release);
            let _ = e; // intentionally swallow; disk persistence is best-effort
        }
    }
}

pub struct TerminalManager {
    sessions: Arc<Mutex<HashMap<String, PtySession>>>,
    /// Shared disk store for scrollback persistence. Bound to `app_data_dir`
    /// during Tauri `setup()`; until then `save`/`load` are no-ops.
    scrollback: Arc<ScrollbackStore>,
}

impl TerminalManager {
    pub fn new() -> Self {
        Self {
            sessions: Arc::new(Mutex::new(HashMap::new())),
            scrollback: Arc::new(ScrollbackStore::new()),
        }
    }

    /// Bind the scrollback store to `{app_data_dir}/scrollback` and run a
    /// best-effort GC pass. Call once from Tauri `setup()`.
    pub fn init_scrollback(&self, app_data_dir: &std::path::Path) {
        if self.scrollback.init_in(app_data_dir) {
            // Opportunistic retention/global-cap GC at startup.
            let _ = self.scrollback.gc();
        }
    }

    /// Access the shared scrollback store (for Tauri commands).
    pub fn scrollback_store(&self) -> Arc<ScrollbackStore> {
        self.scrollback.clone()
    }

    /// Flush every live session's scrollback synchronously, then abort readers
    /// and drop sessions. Called on app quit; uses blocking `std::fs` writes so
    /// it does not depend on the tokio runtime still being up.
    pub fn close_all_sync(&self) {
        let mut sessions = self.sessions.lock().unwrap();
        for (_, session) in sessions.drain() {
            // Final blocking flush before teardown (force dirty so we capture
            // whatever the debounce task may have missed in the last <1s).
            session.scrollback.dirty.store(true, Ordering::Release);
            session.scrollback.flush_if_dirty();
            session.reader_abort.store(true, Ordering::Relaxed);
            drop(session);
        }
    }
}

fn default_shell() -> String {
    std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".to_string())
}

fn is_utf8_locale(value: &str) -> bool {
    let upper = value.to_ascii_uppercase();
    upper.contains("UTF-8") || upper.contains("UTF8")
}

fn env_value_is_utf8(name: &str) -> bool {
    std::env::var(name)
        .ok()
        .filter(|value| !value.trim().is_empty())
        .is_some_and(|value| is_utf8_locale(&value))
}

/// GUI-launched macOS apps do not consistently inherit the user's shell locale.
/// Force a UTF-8 character type locale for the child PTY when the inherited
/// environment is missing/non-UTF-8; otherwise shells/readline/TUIs can treat
/// Hangul bytes as single-byte input and show split/dropped characters.
fn ensure_utf8_locale(cmd: &mut CommandBuilder) {
    const DEFAULT_UTF8_LOCALE: &str = "en_US.UTF-8";

    match std::env::var("LC_ALL") {
        Ok(value) if !value.trim().is_empty() => {
            if !is_utf8_locale(&value) {
                cmd.env("LC_ALL", DEFAULT_UTF8_LOCALE);
            }
            // LC_ALL overrides all LC_* and LANG, so the rest is irrelevant.
            return;
        }
        _ => {}
    }

    if !env_value_is_utf8("LC_CTYPE") {
        cmd.env("LC_CTYPE", DEFAULT_UTF8_LOCALE);
    }
    if !env_value_is_utf8("LANG") {
        cmd.env("LANG", DEFAULT_UTF8_LOCALE);
    }
}

/// Spawn a reader task that streams PTY output to the channel and buffer.
fn spawn_reader(
    mut reader: Box<dyn Read + Send>,
    on_output: Channel<TerminalOutput>,
    abort_flag: Arc<AtomicBool>,
    output_buffer: Arc<Mutex<VecDeque<String>>>,
    is_connected: Arc<AtomicBool>,
    scrollback_dirty: Arc<AtomicBool>,
) {
    is_connected.store(true, Ordering::Relaxed);
    tokio::task::spawn_blocking(move || {
        let mut buf = [0u8; 4096];
        let mut leftover = Vec::new();
        loop {
            if abort_flag.load(Ordering::Relaxed) {
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
                        // Mark scrollback dirty; the debounce task flushes it.
                        scrollback_dirty.store(true, Ordering::Release);

                        if on_output.send(TerminalOutput::Data { data }).is_err() {
                            // Channel disconnected (webview reloaded)
                            is_connected.store(false, Ordering::Relaxed);
                            // Keep reading into buffer instead of breaking
                            drain_to_buffer_only(
                                reader,
                                leftover,
                                abort_flag,
                                output_buffer,
                                scrollback_dirty,
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
        is_connected.store(false, Ordering::Relaxed);
    });
}

/// When channel disconnects, keep reading PTY output into the buffer
/// so it can be replayed on reconnection.
fn drain_to_buffer_only(
    mut reader: Box<dyn Read + Send>,
    mut leftover: Vec<u8>,
    abort_flag: Arc<AtomicBool>,
    output_buffer: Arc<Mutex<VecDeque<String>>>,
    scrollback_dirty: Arc<AtomicBool>,
) {
    let mut buf = [0u8; 4096];
    loop {
        if abort_flag.load(Ordering::Relaxed) {
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
                    scrollback_dirty.store(true, Ordering::Release);
                }
            }
            Err(_) => break,
        }
    }
}

/// Spawn the per-session debounce task that periodically flushes dirty
/// scrollback to disk. The task ends when the session's reader is aborted.
fn spawn_scrollback_flusher(handle: ScrollbackHandle, abort_flag: Arc<AtomicBool>) {
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(SCROLLBACK_FLUSH_INTERVAL);
        loop {
            ticker.tick().await;
            if abort_flag.load(Ordering::Relaxed) {
                // One last flush on the way out, then stop.
                handle.flush_if_dirty();
                break;
            }
            handle.flush_if_dirty();
        }
    });
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
    cmd.env("TERM", "xterm-256color");
    cmd.env("COLORTERM", "truecolor");
    ensure_utf8_locale(&mut cmd);

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

    let abort_flag = Arc::new(AtomicBool::new(false));
    let output_buffer = Arc::new(Mutex::new(VecDeque::new()));
    let is_connected = Arc::new(AtomicBool::new(false));
    let scrollback_dirty = Arc::new(AtomicBool::new(false));

    let scrollback = ScrollbackHandle {
        store: state.scrollback_store(),
        pty_id: terminal_id.clone(),
        cwd: cwd.clone(),
        buffer: output_buffer.clone(),
        dirty: scrollback_dirty.clone(),
    };

    spawn_reader(
        reader,
        on_output,
        abort_flag.clone(),
        output_buffer.clone(),
        is_connected.clone(),
        scrollback_dirty.clone(),
    );

    // Per-session debounce flusher: persists scrollback ~once/sec when dirty.
    spawn_scrollback_flusher(scrollback.clone(), abort_flag.clone());

    let session = PtySession {
        master: pair.master,
        writer: Box::new(writer),
        reader_abort: abort_flag,
        output_buffer,
        is_connected,
        scrollback,
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
        // Persist (don't delete) the latest scrollback so the tab can be
        // reopened as an archive. Per council 쟁점 C, explicit close keeps the
        // record until an explicit "delete" (deleteScrollbackOnTabClose=false).
        session.scrollback.dirty.store(true, Ordering::Release);
        session.scrollback.flush_if_dirty();
        session.reader_abort.store(true, Ordering::Relaxed);
        drop(session);
    }

    Ok(())
}

#[tauri::command]
pub async fn terminal_close_all(state: tauri::State<'_, TerminalManager>) -> Result<(), String> {
    let mut sessions = state
        .sessions
        .lock()
        .map_err(|e| format!("Lock 실패: {}", e))?;

    for (_, session) in sessions.drain() {
        session.scrollback.dirty.store(true, Ordering::Release);
        session.scrollback.flush_if_dirty();
        session.reader_abort.store(true, Ordering::Relaxed);
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
            is_connected: session.is_connected.load(Ordering::Relaxed),
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

    // Spawn a new reader task (re-uses the same scrollback dirty flag).
    spawn_reader(
        new_reader,
        on_output,
        session.reader_abort.clone(),
        session.output_buffer.clone(),
        session.is_connected.clone(),
        session.scrollback.dirty.clone(),
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

// ---------------------------------------------------------------------------
// Scrollback persistence Tauri commands (archive tab backend)
// ---------------------------------------------------------------------------

/// Payload returned by `load_scrollback`: the replay-ready text (already
/// ANSI-straddle corrected and valid UTF-8, ready to `term.write()`), plus the
/// metadata the frontend needs to render the archive banner.
#[derive(Clone, Serialize)]
pub struct ScrollbackPayload {
    /// Replay text. `None` if no archive exists for this id.
    #[serde(rename = "text")]
    pub text: Option<String>,
    #[serde(rename = "cwd", skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(rename = "title", skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(rename = "closedAt", skip_serializing_if = "Option::is_none")]
    pub closed_at: Option<String>,
    #[serde(rename = "byteLen")]
    pub byte_len: u64,
}

/// Load a session's persisted scrollback for replay into a read-only archive
/// tab. Returns `text: None` when there is no archive. Never errors on corrupt
/// files (best-effort recovery).
#[tauri::command]
pub async fn load_scrollback(
    state: tauri::State<'_, TerminalManager>,
    terminal_id: String,
) -> Result<ScrollbackPayload, String> {
    let store = state.scrollback_store();
    let text = store
        .load(&terminal_id)
        .map_err(|e| format!("scrollback load 실패: {}", e))?;
    let meta = store.load_meta(&terminal_id);
    Ok(ScrollbackPayload {
        text,
        cwd: meta.as_ref().and_then(|m| m.cwd.clone()),
        title: meta.as_ref().and_then(|m| m.title.clone()),
        closed_at: meta.as_ref().and_then(|m| m.closed_at.clone()),
        byte_len: meta.as_ref().map(|m| m.byte_len).unwrap_or(0),
    })
}

/// Delete a single session's persisted scrollback (.bin + .meta.json).
/// Idempotent. This is the explicit "기록 삭제" action.
#[tauri::command]
pub async fn delete_scrollback(
    state: tauri::State<'_, TerminalManager>,
    terminal_id: String,
) -> Result<(), String> {
    state
        .scrollback_store()
        .delete(&terminal_id)
        .map_err(|e| format!("scrollback delete 실패: {}", e))
}

/// Delete every persisted scrollback file (settings "전체 지우기").
#[tauri::command]
pub async fn clear_all_scrollback(
    state: tauri::State<'_, TerminalManager>,
) -> Result<(), String> {
    state
        .scrollback_store()
        .clear_all()
        .map_err(|e| format!("scrollback clear_all 실패: {}", e))
}

/// List archived sessions (those with a persisted scrollback file but no live
/// PTY), newest first. The frontend cross-references this against `terminal_list`
/// to render archive vs live tabs.
#[tauri::command]
pub async fn list_archived_sessions(
    state: tauri::State<'_, TerminalManager>,
) -> Result<Vec<super::scrollback::ArchivedSession>, String> {
    Ok(state.scrollback_store().list_archived())
}

#[cfg(test)]
mod tests {
    use super::{find_utf8_boundary, is_utf8_locale, ScrollbackPayload};

    #[test]
    fn locale_detection_accepts_common_utf8_spellings() {
        assert!(is_utf8_locale("en_US.UTF-8"));
        assert!(is_utf8_locale("ko_KR.utf8"));
        assert!(is_utf8_locale("C.UTF-8"));
        assert!(!is_utf8_locale("C"));
        assert!(!is_utf8_locale("ko_KR.EUC-KR"));
    }

    #[test]
    fn utf8_boundary_keeps_partial_hangul_for_next_read() {
        let bytes = "안".as_bytes();
        assert_eq!(find_utf8_boundary(bytes), bytes.len());
        assert_eq!(find_utf8_boundary(&bytes[..2]), 0);

        let mut mixed = "a".as_bytes().to_vec();
        mixed.extend_from_slice(&bytes[..2]);
        assert_eq!(find_utf8_boundary(&mixed), 1);
    }

    /// Guard against the Tauri-Serde-Rename bidirectional trap: the JSON the
    /// frontend receives must use the camelCase keys the TS interface expects,
    /// or the values silently vanish (undefined) on the frontend.
    #[test]
    fn scrollback_payload_serializes_camelcase_keys() {
        let payload = ScrollbackPayload {
            text: Some("hello".into()),
            cwd: Some("/repo".into()),
            title: Some("Claude".into()),
            closed_at: Some("2026-06-01T00:00:00+00:00".into()),
            byte_len: 42,
        };
        let json = serde_json::to_string(&payload).unwrap();
        assert!(json.contains("\"text\":"), "json: {json}");
        assert!(json.contains("\"cwd\":"), "json: {json}");
        assert!(json.contains("\"closedAt\":"), "json: {json}");
        assert!(json.contains("\"byteLen\":"), "json: {json}");
        // The underscore field name must NOT leak as a JSON key.
        assert!(!json.contains("closed_at"), "json: {json}");
        assert!(!json.contains("byte_len"), "json: {json}");

        // None fields with skip_serializing_if must be absent, not null.
        let empty = ScrollbackPayload {
            text: None,
            cwd: None,
            title: None,
            closed_at: None,
            byte_len: 0,
        };
        let json = serde_json::to_string(&empty).unwrap();
        assert!(!json.contains("\"cwd\""), "json: {json}");
        assert!(!json.contains("\"closedAt\""), "json: {json}");
        // text and byteLen are always present.
        assert!(json.contains("\"text\":null"), "json: {json}");
        assert!(json.contains("\"byteLen\":0"), "json: {json}");
    }
}
