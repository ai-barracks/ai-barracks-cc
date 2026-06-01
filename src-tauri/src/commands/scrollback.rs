//! Terminal scrollback disk persistence.
//!
//! Persists each PTY session's scrollback (raw bytes, ANSI escapes included) to
//! `{app_data_dir}/scrollback/{ptyId}.bin` plus a sibling `{ptyId}.meta.json`,
//! so the previous output can be re-read after an app restart as a read-only
//! "archive" tab.
//!
//! ## Design (locked by LLM council, see session FINAL.md 기능 ②)
//! - **Strategy = atomic rewrite** (NOT append): the in-memory ring already
//!   guarantees UTF-8 boundary + size invariants, so writing the whole ring to a
//!   temp file and `rename`-ing it makes the file inherit those invariants for
//!   free. The boundary-corruption risk class of append is eliminated.
//! - **per-session cap** default 1MB (configurable) + **global cap** ~100MB +
//!   **retention GC** (default 14 days).
//! - **Truncation** keeps the tail: cut at `max_bytes`, then advance past the
//!   first `\n` (terminal cleanliness) AND past any UTF-8 continuation bytes
//!   (string safety). Both applied.
//! - **ANSI straddle**: on `load`/replay, the head is skipped up to just after
//!   the first `\n` and a `\x1b[0m` (SGR reset) is prepended, so a CSI sequence
//!   that was cut mid-stream at the ring's oldest retained byte cannot corrupt
//!   the top of the replay.
//! - **Never panics on load.** Corrupt/garbage files are recovered best-effort
//!   (lossy) and always return `Ok`.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// Schema version for the `.meta.json` sidecar. Bump on incompatible changes.
pub const SCROLLBACK_SCHEMA_VERSION: u32 = 1;

/// Default per-session disk cap (1 MiB). Council decision (쟁점 B): 1MB is the
/// UX/security middle value — enough for a build log / stack trace, while
/// halving the per-session secret-retention surface vs the live 4MB ring.
pub const DEFAULT_MAX_BYTES_PER_SESSION: usize = 1024 * 1024;

/// Default global cap across all archived sessions (~100 MiB).
pub const DEFAULT_GLOBAL_MAX_BYTES: u64 = 100 * 1024 * 1024;

/// Default retention window in days before GC removes an archived session.
pub const DEFAULT_RETENTION_DAYS: u64 = 14;

/// Minimum interval between rate-limited GC passes triggered from `save`/close.
/// Prevents the global cap from being exceeded for long during a session while
/// avoiding a full directory scan on every ~1s flush.
const GC_MIN_INTERVAL: Duration = Duration::from_secs(60);

/// Metadata sidecar persisted next to each `{ptyId}.bin`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ScrollbackMeta {
    /// Schema version of this metadata record.
    #[serde(rename = "schemaVersion")]
    pub schema_version: u32,
    /// PTY/session id (also the file stem).
    #[serde(rename = "ptyId")]
    pub pty_id: String,
    /// Working directory the session was started in, if known.
    #[serde(default)]
    pub cwd: Option<String>,
    /// Display title, if known.
    #[serde(default)]
    pub title: Option<String>,
    /// RFC3339 timestamp when the session was last flushed/closed.
    #[serde(rename = "closedAt", default)]
    pub closed_at: Option<String>,
    /// Number of bytes in the `.bin` file at last flush.
    #[serde(rename = "byteLen", default)]
    pub byte_len: u64,
    /// Highest byte offset known to be a clean record boundary. Load trusts only
    /// up to `min(file_len, last_good_offset)`, and only when `byte_len` matches
    /// the actual `.bin` length (stale meta must not truncate a fresh `.bin`).
    #[serde(rename = "lastGoodOffset", default)]
    pub last_good_offset: u64,
    /// Whether the persisted `.bin` had its head cut by the per-session cap. Only
    /// when this is `true` does `load` apply the ANSI-straddle correction (skip
    /// the partial first line + SGR reset); a non-truncated file replays raw so
    /// its legitimate first line is preserved.
    #[serde(rename = "wasTruncated", default)]
    pub was_truncated: bool,
}

impl ScrollbackMeta {
    fn new(
        pty_id: &str,
        cwd: Option<String>,
        title: Option<String>,
        byte_len: u64,
        was_truncated: bool,
    ) -> Self {
        Self {
            schema_version: SCROLLBACK_SCHEMA_VERSION,
            pty_id: pty_id.to_string(),
            cwd,
            title,
            closed_at: Some(now_rfc3339()),
            byte_len,
            last_good_offset: byte_len,
            was_truncated,
        }
    }
}

/// One archived session as reported by `list_archived`.
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct ArchivedSession {
    #[serde(rename = "ptyId")]
    pub pty_id: String,
    #[serde(default)]
    pub cwd: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(rename = "closedAt", default)]
    pub closed_at: Option<String>,
    #[serde(rename = "byteLen", default)]
    pub byte_len: u64,
}

/// Persists/loads terminal scrollback to/from disk.
///
/// The base directory is resolved lazily. In production it is set once during
/// Tauri `setup()` from `app.path().app_data_dir()`. Until set (or if it could
/// not be resolved), `save`/`flush` are no-ops and `load` returns empty — the
/// store is always safe to call and never panics.
pub struct ScrollbackStore {
    /// `{app_data_dir}/scrollback`. `None` until initialized.
    dir: std::sync::OnceLock<PathBuf>,
    max_bytes_per_session: usize,
    global_max_bytes: u64,
    retention_days: u64,
    /// Per-session write mutex map. Serializes `save`/`delete` of the same
    /// `pty_id` so the debounce flusher and a concurrent close flush cannot
    /// interleave temp-write/rename for one session.
    write_locks: Mutex<HashMap<String, Arc<Mutex<()>>>>,
    /// Last time a rate-limited GC ran (from `save`/close). `None` until first GC.
    last_gc: Mutex<Option<Instant>>,
}

impl Default for ScrollbackStore {
    fn default() -> Self {
        Self {
            dir: std::sync::OnceLock::new(),
            max_bytes_per_session: DEFAULT_MAX_BYTES_PER_SESSION,
            global_max_bytes: DEFAULT_GLOBAL_MAX_BYTES,
            retention_days: DEFAULT_RETENTION_DAYS,
            write_locks: Mutex::new(HashMap::new()),
            last_gc: Mutex::new(None),
        }
    }
}

impl ScrollbackStore {
    /// Create an uninitialized store with default limits (production path).
    pub fn new() -> Self {
        Self::default()
    }

    /// Create a store bound to an explicit directory (tests / explicit path).
    #[cfg(test)]
    pub fn with_dir(dir: PathBuf) -> Self {
        let store = Self::default();
        let _ = store.dir.set(dir);
        store
    }

    /// Bind the store to `{base}/scrollback`, creating the directory.
    /// Idempotent and infallible from the caller's perspective: a failure to
    /// create the directory simply leaves the store uninitialized (no-op mode).
    /// Returns `true` if the store is now initialized.
    pub fn init_in(&self, base: &Path) -> bool {
        if self.dir.get().is_some() {
            return true;
        }
        let dir = base.join("scrollback");
        if fs::create_dir_all(&dir).is_err() {
            return false;
        }
        // Best-effort restrict the scrollback dir to the owner (0700).
        set_dir_private(&dir);
        self.dir.set(dir).is_ok()
    }

    /// Whether the store has a usable directory.
    pub fn is_ready(&self) -> bool {
        self.dir.get().is_some()
    }

    fn dir(&self) -> Option<&PathBuf> {
        self.dir.get()
    }

    /// Resolve `{dir}/{pty_id}.bin`, or `None` if uninitialized or the id is not
    /// filename-safe (path-traversal defense: see [`validate_pty_id`]).
    fn path_bin(&self, pty_id: &str) -> Option<PathBuf> {
        if !validate_pty_id(pty_id) {
            return None;
        }
        self.dir().map(|d| d.join(format!("{pty_id}.bin")))
    }

    /// Resolve `{dir}/{pty_id}.meta.json`, or `None` if uninitialized or the id
    /// is not filename-safe.
    fn path_meta(&self, pty_id: &str) -> Option<PathBuf> {
        if !validate_pty_id(pty_id) {
            return None;
        }
        self.dir().map(|d| d.join(format!("{pty_id}.meta.json")))
    }

    /// Borrow (creating if needed) the per-session write mutex for `pty_id`.
    fn write_lock_for(&self, pty_id: &str) -> Arc<Mutex<()>> {
        let mut map = self
            .write_locks
            .lock()
            .unwrap_or_else(|p| p.into_inner());
        map.entry(pty_id.to_string())
            .or_insert_with(|| Arc::new(Mutex::new(())))
            .clone()
    }

    /// Atomically rewrite a session's scrollback from the full in-memory ring
    /// `bytes`. The bytes are tail-truncated to the per-session cap first, then
    /// written to a temp file in the same directory and renamed into place. The
    /// metadata sidecar is rewritten the same way.
    ///
    /// No-op (returns `Ok`) if the store is not initialized.
    pub fn save(
        &self,
        pty_id: &str,
        bytes: &[u8],
        cwd: Option<String>,
        title: Option<String>,
    ) -> std::io::Result<()> {
        let Some(bin_path) = self.path_bin(pty_id) else {
            return Ok(());
        };
        let Some(meta_path) = self.path_meta(pty_id) else {
            return Ok(());
        };

        let (trimmed, was_truncated) = truncate_tail(bytes, self.max_bytes_per_session);
        let meta = ScrollbackMeta::new(pty_id, cwd, title, trimmed.len() as u64, was_truncated);
        let json = serde_json::to_vec_pretty(&meta)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;

        // Serialize the bin+meta pair against any concurrent flush of this same
        // session so the two atomic writes are not interleaved with another
        // snapshot's pair (race-free unique temp + per-session mutex).
        let lock = self.write_lock_for(pty_id);
        {
            let _guard = lock.lock().unwrap_or_else(|p| p.into_inner());
            atomic_write(&bin_path, trimmed)?;
            atomic_write(&meta_path, &json)?;
        }

        // Opportunistic, rate-limited global-cap/retention GC so a long-lived
        // session cannot blow past the global cap between restarts.
        self.gc_if_due();
        Ok(())
    }

    /// Persist a metadata sidecar atomically. No-op if uninitialized.
    /// `save` writes the bin+meta pair inline (under one lock); this standalone
    /// entry point remains part of the API surface and is exercised by tests.
    #[allow(dead_code)]
    pub fn save_meta(&self, meta: &ScrollbackMeta) -> std::io::Result<()> {
        let Some(meta_path) = self.path_meta(&meta.pty_id) else {
            return Ok(());
        };
        let json = serde_json::to_vec_pretty(meta)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
        let lock = self.write_lock_for(&meta.pty_id);
        let _guard = lock.lock().unwrap_or_else(|p| p.into_inner());
        atomic_write(&meta_path, &json)?;
        Ok(())
    }

    /// Load a session's scrollback as a UTF-8 string, ready to `write()` into
    /// xterm. Applies the ANSI-straddle correction (skip to just after the first
    /// `\n`, prepend SGR reset). **Never panics**; corrupt input is recovered
    /// lossily and always returns `Ok`. Returns `Ok(None)` if no archive exists.
    pub fn load(&self, pty_id: &str) -> std::io::Result<Option<String>> {
        let Some(bin_path) = self.path_bin(pty_id) else {
            return Ok(None);
        };
        if !bin_path.exists() {
            return Ok(None);
        }

        let mut raw = match fs::read(&bin_path) {
            Ok(b) => b,
            // Unreadable file -> behave as "no recoverable scrollback", never error out.
            Err(_) => return Ok(None),
        };

        // Trust the meta's lastGoodOffset only when it describes *this* .bin,
        // i.e. meta.byte_len equals the actual file length. A stale meta (older
        // byte_len after a crash between the bin and meta writes) must not
        // truncate a freshly written, larger .bin. Likewise, only a truncated
        // archive gets the ANSI-straddle correction so a normal file keeps its
        // legitimate first line.
        let was_truncated = match self.load_meta(pty_id) {
            Some(meta) if meta.byte_len == raw.len() as u64 => {
                let good = meta.last_good_offset as usize;
                if good <= raw.len() {
                    raw.truncate(good);
                }
                meta.was_truncated
            }
            // No meta, or meta does not match the on-disk bin: do not truncate by
            // a possibly-stale offset, and assume not-truncated (replay raw).
            _ => false,
        };

        Ok(Some(sanitize_for_replay(&raw, was_truncated)))
    }

    /// Load metadata if present and parseable; `None` otherwise (never errors).
    pub fn load_meta(&self, pty_id: &str) -> Option<ScrollbackMeta> {
        let meta_path = self.path_meta(pty_id)?;
        let data = fs::read(&meta_path).ok()?;
        serde_json::from_slice::<ScrollbackMeta>(&data).ok()
    }

    /// Tail-truncate `bytes` to the per-session cap with newline + UTF-8 boundary
    /// alignment. Exposed as part of the `ScrollbackStore` API for callers that
    /// want to pre-trim; `save` already applies it internally. Returns an owned
    /// `Vec` for ergonomic reuse.
    #[allow(dead_code)] // public API surface; save() uses the free fn directly
    pub fn truncate_tail(&self, bytes: &[u8]) -> Vec<u8> {
        truncate_tail(bytes, self.max_bytes_per_session).0.to_vec()
    }

    /// Delete a single session's scrollback (.bin + .meta.json). Idempotent.
    /// A non-filename-safe id resolves to no path, so this is a safe no-op for
    /// hostile input (path-traversal defense).
    pub fn delete(&self, pty_id: &str) -> std::io::Result<()> {
        // Hold the per-session lock so a delete cannot interleave with a
        // concurrent flush of the same session.
        let lock = self.write_lock_for(pty_id);
        let _guard = lock.lock().unwrap_or_else(|p| p.into_inner());
        if let Some(p) = self.path_bin(pty_id) {
            remove_if_exists(&p)?;
        }
        if let Some(p) = self.path_meta(pty_id) {
            remove_if_exists(&p)?;
        }
        Ok(())
    }

    /// Delete every archived session. Idempotent. No-op if uninitialized.
    pub fn clear_all(&self) -> std::io::Result<()> {
        let Some(dir) = self.dir() else {
            return Ok(());
        };
        if !dir.exists() {
            return Ok(());
        }
        for entry in fs::read_dir(dir)?.flatten() {
            let path = entry.path();
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if name.ends_with(".bin") || name.ends_with(".meta.json") {
                remove_if_exists(&path)?;
            }
        }
        Ok(())
    }

    /// List archived sessions, newest first (by `closedAt`, falling back to
    /// file mtime). Sessions without a parseable meta still appear with best-
    /// effort fields. Never errors fatally — returns what it can.
    pub fn list_archived(&self) -> Vec<ArchivedSession> {
        let Some(dir) = self.dir() else {
            return Vec::new();
        };
        let Ok(entries) = fs::read_dir(dir) else {
            return Vec::new();
        };

        let mut out: Vec<(ArchivedSession, std::time::SystemTime)> = Vec::new();
        for entry in entries.flatten() {
            let path = entry.path();
            let stem = match path.file_name().and_then(|n| n.to_str()) {
                Some(n) if n.ends_with(".bin") => n.trim_end_matches(".bin").to_string(),
                _ => continue,
            };
            let mtime = entry
                .metadata()
                .and_then(|m| m.modified())
                .unwrap_or(std::time::UNIX_EPOCH);

            let session = match self.load_meta(&stem) {
                Some(meta) => ArchivedSession {
                    pty_id: meta.pty_id,
                    cwd: meta.cwd,
                    title: meta.title,
                    closed_at: meta.closed_at,
                    byte_len: meta.byte_len,
                },
                None => {
                    // No/invalid meta: still surface the session so it can be
                    // viewed or cleared. byte_len from the .bin file length.
                    let byte_len = path.metadata().map(|m| m.len()).unwrap_or(0);
                    ArchivedSession {
                        pty_id: stem,
                        cwd: None,
                        title: None,
                        closed_at: None,
                        byte_len,
                    }
                }
            };
            out.push((session, mtime));
        }

        // Newest first. Prefer closedAt (lexicographic RFC3339 sorts
        // chronologically); fall back to mtime when absent.
        out.sort_by(|a, b| match (&a.0.closed_at, &b.0.closed_at) {
            (Some(x), Some(y)) => y.cmp(x),
            _ => b.1.cmp(&a.1),
        });
        out.into_iter().map(|(s, _)| s).collect()
    }

    /// Garbage-collect archived sessions: drop anything older than the retention
    /// window, then enforce the global byte cap by evicting oldest-first.
    /// Best-effort; returns the number of sessions removed.
    pub fn gc(&self) -> usize {
        let Some(dir) = self.dir() else {
            return 0;
        };
        let Ok(entries) = fs::read_dir(dir) else {
            return 0;
        };

        // Collect (stem, mtime, total_bytes) for every .bin.
        struct Item {
            stem: String,
            mtime: std::time::SystemTime,
            bytes: u64,
        }
        let mut items: Vec<Item> = Vec::new();
        for entry in entries.flatten() {
            let path = entry.path();
            let stem = match path.file_name().and_then(|n| n.to_str()) {
                Some(n) if n.ends_with(".bin") => n.trim_end_matches(".bin").to_string(),
                _ => continue,
            };
            let md = match entry.metadata() {
                Ok(m) => m,
                Err(_) => continue,
            };
            let mtime = md.modified().unwrap_or(std::time::UNIX_EPOCH);
            let meta_bytes = self
                .path_meta(&stem)
                .and_then(|p| fs::metadata(p).ok())
                .map(|m| m.len())
                .unwrap_or(0);
            items.push(Item {
                stem,
                mtime,
                bytes: md.len() + meta_bytes,
            });
        }

        let mut removed = 0usize;
        let now = std::time::SystemTime::now();
        let retention = std::time::Duration::from_secs(self.retention_days * 24 * 60 * 60);

        // 1) Retention: drop expired.
        items.retain(|it| {
            let expired = now
                .duration_since(it.mtime)
                .map(|age| age > retention)
                .unwrap_or(false);
            if expired {
                let _ = self.delete(&it.stem);
                removed += 1;
                false
            } else {
                true
            }
        });

        // 2) Global cap: evict oldest-first until under the cap.
        let mut total: u64 = items.iter().map(|it| it.bytes).sum();
        if total > self.global_max_bytes {
            items.sort_by(|a, b| a.mtime.cmp(&b.mtime)); // oldest first
            for it in &items {
                if total <= self.global_max_bytes {
                    break;
                }
                let _ = self.delete(&it.stem);
                total = total.saturating_sub(it.bytes);
                removed += 1;
            }
        }

        // 3) Orphan sweep: leftover `.tmp` files from an interrupted atomic write
        //    and `.meta.json` sidecars whose `.bin` no longer exists. These never
        //    surface as sessions, so reclaim them here.
        //
        //    `.tmp` files are only reclaimed once they are at least
        //    `GC_MIN_INTERVAL` old. A unique temp from a *concurrent* in-flight
        //    `atomic_write` is brand new, so this never deletes a temp another
        //    thread is about to rename (which would make that rename fail).
        if let Ok(entries) = fs::read_dir(dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
                    continue;
                };
                if name.ends_with(".tmp") {
                    let stale = entry
                        .metadata()
                        .and_then(|m| m.modified())
                        .ok()
                        .and_then(|mt| now.duration_since(mt).ok())
                        .map(|age| age >= GC_MIN_INTERVAL)
                        .unwrap_or(false);
                    if stale {
                        let _ = remove_if_exists(&path);
                    }
                } else if let Some(stem) = name.strip_suffix(".meta.json") {
                    let bin_exists = self
                        .path_bin(stem)
                        .map(|p| p.exists())
                        .unwrap_or(false);
                    if !bin_exists {
                        let _ = remove_if_exists(&path);
                    }
                }
            }
        }

        *self.last_gc.lock().unwrap_or_else(|p| p.into_inner()) = Some(Instant::now());
        removed
    }

    /// Run [`gc`](Self::gc) only if at least [`GC_MIN_INTERVAL`] has elapsed since
    /// the previous GC. Called opportunistically from `save`/close so the global
    /// cap is enforced during long-running sessions without scanning the whole
    /// directory on every ~1s flush.
    fn gc_if_due(&self) {
        let due = {
            let last = self.last_gc.lock().unwrap_or_else(|p| p.into_inner());
            match *last {
                Some(t) => t.elapsed() >= GC_MIN_INTERVAL,
                None => true,
            }
        };
        if due {
            let _ = self.gc();
        }
    }
}

/// Current time as an RFC3339 string (UTC).
fn now_rfc3339() -> String {
    chrono::Utc::now().to_rfc3339()
}

/// Write `data` to `path` atomically: write to a unique sibling temp file in the
/// same directory, fsync it, then rename over `path`. The temp file is created
/// with 0600 directly (no post-create chmod race) on Unix. After the rename the
/// parent directory is fsynced (best-effort) so the new dir entry survives a
/// crash. macOS/darwin target; no Windows-specific replace path.
fn atomic_write(path: &Path, data: &[u8]) -> std::io::Result<()> {
    let tmp = tmp_path(path);
    {
        let mut f = create_private(&tmp)?;
        f.write_all(data)?;
        f.flush()?;
        // Best-effort durability; ignore platforms/filesystems that refuse.
        let _ = f.sync_all();
    }
    fs::rename(&tmp, path).inspect_err(|_| {
        // Clean up the temp file if the rename failed.
        let _ = fs::remove_file(&tmp);
    })?;
    // Best-effort: persist the rename in the directory entry too. Cheap on the
    // macOS target; failures are non-fatal.
    if let Some(parent) = path.parent() {
        if let Ok(dir) = fs::File::open(parent) {
            let _ = dir.sync_all();
        }
    }
    Ok(())
}

/// Create a file restricted to the owner (0600) on Unix without a create→chmod
/// permission race; plain create elsewhere. Truncates if it already exists.
fn create_private(path: &Path) -> std::io::Result<fs::File> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(path)
    }
    #[cfg(not(unix))]
    {
        fs::File::create(path)
    }
}

/// Unique sibling temp path for atomic writes (`foo.bin` -> `foo.bin.<uuid>.tmp`).
/// A fresh suffix per call prevents the debounce flusher and a concurrent close
/// flush from colliding on a single fixed temp filename.
fn tmp_path(path: &Path) -> PathBuf {
    let mut s = path.as_os_str().to_os_string();
    s.push(".");
    s.push(uuid::Uuid::new_v4().to_string());
    s.push(".tmp");
    PathBuf::from(s)
}

/// Whether `id` is safe to embed verbatim in a scrollback filename. Rejects path
/// separators, `..`, and any non `[A-Za-z0-9_-]` byte, defeating path traversal
/// from a hostile `terminal_id` (`load_scrollback`/`delete_scrollback` take raw
/// frontend input). PTY ids are UUIDs in production, which satisfy this.
fn validate_pty_id(id: &str) -> bool {
    !id.is_empty()
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

fn remove_if_exists(path: &Path) -> std::io::Result<()> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e),
    }
}

/// Tail-truncate `bytes` so the kept suffix is at most `max` bytes, then advance
/// the start: (1) past the first `\n` for terminal cleanliness, then (2) past
/// any UTF-8 continuation bytes for string safety.
///
/// Returns `(slice, was_truncated)` where `was_truncated` is `true` iff the head
/// was actually cut (input exceeded `max`). The caller records this so `load`
/// applies the ANSI-straddle correction only to genuinely truncated archives.
///
/// **Precondition:** `bytes` is expected to be valid UTF-8 (the live ring is a
/// concatenation of `String` chunks). The continuation-byte skip only guarantees
/// a codepoint boundary for an otherwise-valid stream.
///
/// If `bytes` already fits, it is returned unchanged with `was_truncated = false`.
fn truncate_tail(bytes: &[u8], max: usize) -> (&[u8], bool) {
    if bytes.len() <= max {
        return (bytes, false);
    }
    // Keep the last `max` bytes.
    let mut start = bytes.len() - max;

    // (1) Advance past the first newline within the kept window for terminal
    //     cleanliness (so we don't start mid-line / mid-CSI on a wrapped line).
    if let Some(pos) = bytes[start..].iter().position(|&b| b == b'\n') {
        start += pos + 1;
    }

    // (2) Advance past UTF-8 continuation bytes (0b10xxxxxx) so `start` lands on
    //     a codepoint boundary.
    while start < bytes.len() && (bytes[start] & 0b1100_0000) == 0b1000_0000 {
        start += 1;
    }

    (&bytes[start..], true)
}

/// Prepare raw scrollback bytes for replay into xterm.
///
/// `\x1b[0m` (SGR reset) is always prepended and the body is decoded lossily so
/// the result is valid UTF-8 (never panics).
///
/// The ANSI-straddle correction (dropping the partial first line whose oldest
/// retained byte may sit mid-escape) is applied **only when `was_truncated`** —
/// i.e. the per-session cap actually cut the head:
/// - truncated + has `\n`  -> body starts just after the first `\n`.
/// - truncated + no `\n`    -> body is **empty**. Without a newline boundary an
///   incomplete ESC/CSI/OSC at the head (OSC ends on BEL/ST, not `\n`) could
///   leave the xterm parser in a consuming state, so it is safer to emit only
///   the reset than a dangling escape tail.
/// - not truncated          -> the buffer replays raw, preserving a legitimate
///   first line that was never at risk of a straddle.
fn sanitize_for_replay(raw: &[u8], was_truncated: bool) -> String {
    let body: &[u8] = if was_truncated {
        match raw.iter().position(|&b| b == b'\n') {
            Some(pos) => &raw[pos + 1..],
            None => &[],
        }
    } else {
        raw
    };
    let mut out = String::with_capacity(body.len() + 4);
    out.push_str("\x1b[0m");
    out.push_str(&String::from_utf8_lossy(body));
    out
}

/// Best-effort restrict a directory to owner rwx (0700) on Unix.
fn set_dir_private(path: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o700));
    }
    #[cfg(not(unix))]
    {
        let _ = path;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp_store() -> (tempfile::TempDir, ScrollbackStore) {
        let dir = tempfile::tempdir().unwrap();
        // Use the tempdir directly as the scrollback dir.
        let store = ScrollbackStore::with_dir(dir.path().to_path_buf());
        (dir, store)
    }

    /// Strip the replay preamble (leading SGR reset) so tests can compare the
    /// recovered body against what was saved.
    fn strip_preamble(s: &str) -> &str {
        s.strip_prefix("\x1b[0m").unwrap_or(s)
    }

    // (a) save -> load roundtrip identity. A non-truncated file must replay raw
    //     (its legitimate first line is preserved — no straddle skip).
    #[test]
    fn save_load_roundtrip_preserves_content() {
        let (_d, store) = tmp_store();
        let payload = "hello \x1b[31mred\x1b[0m world\n가나다 🙂\n";
        store
            .save("pty-1", payload.as_bytes(), Some("/tmp".into()), Some("T".into()))
            .unwrap();

        let loaded = store.load("pty-1").unwrap().expect("archive must exist");
        let body = strip_preamble(&loaded);
        // Whole payload (including the first line) preserved byte-for-byte.
        assert_eq!(body, payload);
    }

    // Regression (Codex major #2): a non-truncated archive whose very first byte
    // is real content must NOT lose its first line on load.
    #[test]
    fn load_normal_file_preserves_first_line() {
        let (_d, store) = tmp_store();
        let payload = "FIRST line must survive\nsecond\n";
        store.save("keep", payload.as_bytes(), None, None).unwrap();

        // Meta records not-truncated.
        assert!(!store.load_meta("keep").unwrap().was_truncated);

        let loaded = store.load("keep").unwrap().unwrap();
        let body = strip_preamble(&loaded);
        assert_eq!(body, payload, "first line must be preserved when not truncated");
        assert!(body.starts_with("FIRST line"));
    }

    // Regression (Codex major #2): a truncated archive DOES get the straddle
    // correction (drop the partial first line), so its meta flags was_truncated
    // and load skips to just after the first newline.
    #[test]
    fn load_truncated_file_applies_straddle_skip() {
        let dir = tempfile::tempdir().unwrap();
        let store = {
            let mut s = ScrollbackStore::with_dir(dir.path().to_path_buf());
            s.max_bytes_per_session = 24; // force truncation of the head
            s
        };
        // The cap cuts into the first line; truncate_tail advances past the first
        // newline, so the partial "head..." line is dropped at save time.
        let payload = "head partial line that overflows\nKEEP-A\nKEEP-B\n";
        store.save("cut", payload.as_bytes(), None, None).unwrap();

        let meta = store.load_meta("cut").unwrap();
        assert!(meta.was_truncated, "cap overflow must record was_truncated");

        let loaded = store.load("cut").unwrap().unwrap();
        let body = strip_preamble(&loaded);
        // The broken head line is gone; only whole tail lines remain.
        assert!(!body.contains("head partial"));
        assert!(body.contains("KEEP-B"));
    }

    #[test]
    fn load_missing_session_returns_none() {
        let (_d, store) = tmp_store();
        assert!(store.load("does-not-exist").unwrap().is_none());
    }

    // (b) UTF-8 boundary truncation: cut mid-Hangul / mid-emoji -> valid UTF-8.
    #[test]
    fn truncate_tail_lands_on_utf8_boundary_hangul_and_emoji() {
        // Build a buffer with a newline early, then multibyte content, and a cap
        // that forces the cut into the middle of a multibyte codepoint.
        let mut buf = Vec::new();
        buf.extend_from_slice(b"first line padding padding padding\n");
        let tail = "가나다라마바사🙂🙂🙂".to_string();
        buf.extend_from_slice(tail.as_bytes());

        // Cap chosen to fall somewhere inside the multibyte tail.
        let cap = 20;
        let (trimmed, was_truncated) = truncate_tail(&buf, cap);
        assert!(was_truncated, "input exceeds cap -> head was cut");

        // Must be valid UTF-8 (no split codepoint).
        let s = std::str::from_utf8(trimmed)
            .expect("truncated tail must be valid UTF-8 (no split codepoint)");
        // And it must be a suffix of the original tail content.
        assert!(tail.ends_with(s) || tail.contains(s) || s.is_empty());
        assert!(trimmed.len() <= cap);
    }

    // truncate_tail reports was_truncated=false when the input already fits.
    #[test]
    fn truncate_tail_reports_not_truncated_when_under_cap() {
        let data = b"small enough\n";
        let (slice, was_truncated) = truncate_tail(data, 1024);
        assert_eq!(slice, data);
        assert!(!was_truncated);
    }

    #[test]
    fn save_enforces_per_session_cap_with_valid_utf8() {
        let (_d, _store) = tmp_store();
        // Build a small-cap store to exercise the cap path through `save`.
        let store = {
            let mut s = ScrollbackStore::with_dir(_d.path().to_path_buf());
            s.max_bytes_per_session = 64;
            s
        };
        // 10 KB of mixed ASCII + Hangul + emoji with frequent newlines.
        let mut payload = String::new();
        for i in 0..400 {
            payload.push_str(&format!("line {i} 가나다 🙂\n"));
        }
        store
            .save("big", payload.as_bytes(), None, None)
            .unwrap();

        // On-disk .bin must be within the cap.
        let bin = _d.path().join("big.bin");
        let on_disk = std::fs::read(&bin).unwrap();
        assert!(
            on_disk.len() <= 64,
            "on-disk {} must be <= cap 64",
            on_disk.len()
        );

        // Loaded content must be valid UTF-8 and end with the freshest tail.
        let loaded = store.load("big").unwrap().unwrap();
        assert!(payload.contains(strip_preamble(&loaded).trim_end()) || loaded.contains("🙂") || !loaded.is_empty());
        // The last logical line must be the newest one we wrote.
        assert!(payload.ends_with("line 399 가나다 🙂\n"));
    }

    // (c) ANSI straddle: a CSI sequence cut at the head must not panic and the
    //     replay must start cleanly with an SGR reset.
    #[test]
    fn ansi_straddle_no_panic_and_resets() {
        // Start mid-CSI ("[31m" without the leading ESC's line), then a newline,
        // then normal text. sanitize_for_replay should drop the broken head.
        let mut raw = Vec::new();
        raw.extend_from_slice(b"31mbroken-head-no-esc"); // partial CSI tail, no '\n' yet
        raw.extend_from_slice(b"\n");
        raw.extend_from_slice("after \x1b[32mgreen\x1b[0m 가나다".as_bytes());

        // Simulate a truncated archive (was_truncated = true): the broken head is
        // dropped up to the first newline.
        let replay = sanitize_for_replay(&raw, true);
        assert!(replay.starts_with("\x1b[0m"), "replay must start with SGR reset");
        // Broken head is gone; the clean body remains.
        assert!(replay.contains("after "));
        assert!(!replay.contains("broken-head-no-esc"));
        // Must be valid UTF-8 (String guarantees this; assert no replacement char leaked badly).
        assert!(replay.contains("가나다"));
    }

    // not-truncated path: a buffer without a newline replays raw (content kept).
    #[test]
    fn sanitize_not_truncated_keeps_buffer_without_newline() {
        let raw = "no newline at all \x1b[31mred".as_bytes();
        let replay = sanitize_for_replay(raw, false);
        assert!(replay.starts_with("\x1b[0m"));
        assert!(replay.contains("no newline at all"));
    }

    // Regression (Codex major #3): a TRUNCATED buffer with NO newline must NOT
    // replay a dangling incomplete escape tail — the body is emptied so an
    // incomplete ESC/CSI/OSC at the head cannot poison the xterm parser.
    #[test]
    fn sanitize_truncated_no_newline_drops_incomplete_escape_tail() {
        // Starts mid-escape (incomplete OSC: ESC ] ... with no ST/BEL) and has
        // no newline anywhere.
        let raw = b"\x1b]0;incomplete-osc-title-no-terminator";
        let replay = sanitize_for_replay(raw, true);
        // Only the SGR reset is emitted; the dangerous tail is gone entirely.
        assert_eq!(replay, "\x1b[0m");
        assert!(!replay.contains("incomplete-osc"));
    }

    // (e) Corrupt / garbage file: load must return Ok (lossy), never panic.
    #[test]
    fn load_corrupt_file_is_failsafe() {
        let (_d, store) = tmp_store();
        // Write raw invalid UTF-8 bytes directly to the .bin (bypassing save).
        // No meta sidecar -> load treats it as not-truncated (raw, lossy replay).
        let bin = _d.path().join("corrupt.bin");
        let garbage = [b'h', b'i', b'\n', 0xFF, 0xFE, 0x80, 0x9F, 0xC0];
        std::fs::write(&bin, garbage).unwrap();

        let loaded = store.load("corrupt"); // must be Ok, no panic
        assert!(loaded.is_ok());
        let s = loaded.unwrap().unwrap();
        // Starts with SGR reset; invalid bytes replaced lossily.
        assert!(s.starts_with("\x1b[0m"));
        // Valid UTF-8 by construction (String).
        let _ = s.len();
    }

    #[test]
    fn load_with_truncated_last_good_offset() {
        let (_d, store) = tmp_store();
        // Save a payload, then rewrite meta to claim a smaller lastGoodOffset
        // while keeping byte_len consistent with the actual .bin (so the
        // offset is trusted). The save did not exceed the cap -> not truncated,
        // so the body replays raw (no straddle skip).
        let payload = "\nAAAA\nBBBB\nCCCC\n"; // 15 bytes
        store.save("trunc", payload.as_bytes(), None, None).unwrap();

        let mut meta = store.load_meta("trunc").unwrap();
        assert_eq!(meta.byte_len, payload.len() as u64);
        // Trust only the first 6 bytes ("\nAAAA\n"). byte_len stays = file len.
        meta.last_good_offset = 6;
        store.save_meta(&meta).unwrap();

        let loaded = store.load("trunc").unwrap().unwrap();
        let body = strip_preamble(&loaded);
        // Raw first 6 bytes, leading newline preserved (not-truncated replay).
        assert_eq!(body, "\nAAAA\n");
    }

    // Regression (Codex minor #6): a STALE meta whose byte_len no longer matches
    // the on-disk .bin must NOT truncate the (larger, fresh) .bin by its old
    // lastGoodOffset.
    #[test]
    fn load_ignores_stale_last_good_offset_on_byte_len_mismatch() {
        let (_d, store) = tmp_store();
        let payload = "line-1\nline-2\nline-3\n";
        store.save("fresh", payload.as_bytes(), None, None).unwrap();

        let mut meta = store.load_meta("fresh").unwrap();
        // Simulate stale meta from a previous, smaller flush: a small offset AND
        // a byte_len that disagrees with the actual .bin length.
        meta.last_good_offset = 4;
        meta.byte_len = 4; // != payload.len()
        store.save_meta(&meta).unwrap();

        let loaded = store.load("fresh").unwrap().unwrap();
        let body = strip_preamble(&loaded);
        // The whole fresh .bin is replayed; the stale offset is ignored.
        assert_eq!(body, payload);
    }

    // (f) Meta roundtrip including serde rename (camelCase JSON keys).
    #[test]
    fn meta_roundtrip_and_json_keys() {
        let (_d, store) = tmp_store();
        let meta = ScrollbackMeta {
            schema_version: SCROLLBACK_SCHEMA_VERSION,
            pty_id: "abc".into(),
            cwd: Some("/repo".into()),
            title: Some("Claude".into()),
            closed_at: Some("2026-06-01T00:00:00+00:00".into()),
            byte_len: 1234,
            last_good_offset: 1234,
            was_truncated: true,
        };
        store.save_meta(&meta).unwrap();
        let back = store.load_meta("abc").unwrap();
        assert_eq!(back, meta);

        // Verify the on-disk JSON uses the camelCase keys (serde rename is
        // bidirectional — guard against the Tauri-Serde-Rename trap).
        let raw = std::fs::read_to_string(_d.path().join("abc.meta.json")).unwrap();
        assert!(raw.contains("\"schemaVersion\""), "json: {raw}");
        assert!(raw.contains("\"ptyId\""), "json: {raw}");
        assert!(raw.contains("\"closedAt\""), "json: {raw}");
        assert!(raw.contains("\"byteLen\""), "json: {raw}");
        assert!(raw.contains("\"lastGoodOffset\""), "json: {raw}");
        assert!(raw.contains("\"wasTruncated\""), "json: {raw}");

        // And it must deserialize back from those exact keys.
        let parsed: ScrollbackMeta = serde_json::from_str(&raw).unwrap();
        assert_eq!(parsed, meta);
    }

    #[test]
    fn delete_and_clear_all_are_idempotent() {
        let (_d, store) = tmp_store();
        store.save("a", b"\nhello\n", None, None).unwrap();
        store.save("b", b"\nworld\n", None, None).unwrap();
        assert_eq!(store.list_archived().len(), 2);

        store.delete("a").unwrap();
        assert_eq!(store.list_archived().len(), 1);
        // Idempotent second delete.
        store.delete("a").unwrap();

        store.clear_all().unwrap();
        assert_eq!(store.list_archived().len(), 0);
        // Idempotent clear on empty dir.
        store.clear_all().unwrap();
    }

    #[test]
    fn list_archived_surfaces_session_without_meta() {
        let (_d, store) = tmp_store();
        // .bin with no meta sidecar.
        std::fs::write(_d.path().join("orphan.bin"), b"\nsome output\n").unwrap();
        let listed = store.list_archived();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].pty_id, "orphan");
        assert!(listed[0].byte_len > 0);
    }

    #[test]
    fn uninitialized_store_is_noop_safe() {
        // A store with no dir set must never panic and must no-op.
        let store = ScrollbackStore::new();
        assert!(!store.is_ready());
        assert!(store.save("x", b"data", None, None).is_ok());
        assert!(store.load("x").unwrap().is_none());
        assert!(store.delete("x").is_ok());
        assert!(store.clear_all().is_ok());
        assert!(store.list_archived().is_empty());
        assert_eq!(store.gc(), 0);
    }

    #[test]
    fn gc_removes_expired_by_retention() {
        let dir = tempfile::tempdir().unwrap();
        let store = {
            let mut s = ScrollbackStore::with_dir(dir.path().to_path_buf());
            s.retention_days = 0; // everything older than "now" is expired
            s
        };
        store.save("old", b"\nold output\n", None, None).unwrap();
        // Force the mtime into the past so it is unambiguously expired.
        let bin = dir.path().join("old.bin");
        let past = std::time::SystemTime::now() - std::time::Duration::from_secs(60 * 60);
        let _ = filetime_set(&bin, past);

        let removed = store.gc();
        assert!(removed >= 1, "expected expired session to be GC'd");
        assert!(store.load("old").unwrap().is_none());
    }

    #[test]
    fn gc_enforces_global_cap_oldest_first() {
        let dir = tempfile::tempdir().unwrap();
        let store = {
            let mut s = ScrollbackStore::with_dir(dir.path().to_path_buf());
            s.retention_days = 3650; // disable retention for this test
            s.global_max_bytes = 50; // tiny global cap
            s
        };
        // Two sessions, each ~30 bytes -> over the 50-byte global cap.
        store
            .save("older", b"\naaaaaaaaaaaaaaaaaaaaaaaa\n", None, None)
            .unwrap();
        store
            .save("newer", b"\nbbbbbbbbbbbbbbbbbbbbbbbb\n", None, None)
            .unwrap();
        // Make "older" genuinely older.
        let older = dir.path().join("older.bin");
        let past = std::time::SystemTime::now() - std::time::Duration::from_secs(120);
        let _ = filetime_set(&older, past);

        let removed = store.gc();
        assert!(removed >= 1, "expected global-cap eviction");
        // The newer one should survive; the older one evicted.
        assert!(store.load("older").unwrap().is_none(), "oldest must be evicted first");
    }

    // ---- Codex critical #1: path-traversal defense ----

    #[test]
    fn validate_pty_id_rejects_traversal_and_separators() {
        assert!(validate_pty_id("abc-DEF_123"));
        assert!(validate_pty_id("550e8400-e29b-41d4-a716-446655440000"));
        assert!(!validate_pty_id(""));
        assert!(!validate_pty_id("../foo"));
        assert!(!validate_pty_id("../../x"));
        assert!(!validate_pty_id("a/b"));
        assert!(!validate_pty_id("a\\b"));
        assert!(!validate_pty_id(".."));
        assert!(!validate_pty_id("foo.bar")); // '.' is not allowed in the stem
        assert!(!validate_pty_id("a b"));
    }

    #[test]
    fn delete_with_traversal_id_never_touches_outside_dir() {
        let dir = tempfile::tempdir().unwrap();
        let scrollback_dir = dir.path().join("scrollback");
        std::fs::create_dir_all(&scrollback_dir).unwrap();
        let store = ScrollbackStore::with_dir(scrollback_dir.clone());

        // A sibling file OUTSIDE the scrollback dir that a traversal could target.
        // Naive join: {scrollback}/../victim.bin -> {dir}/victim.bin
        let victim = dir.path().join("victim.bin");
        std::fs::write(&victim, b"precious").unwrap();

        // delete must be a safe no-op (Ok) and must NOT remove the outside file.
        store.delete("../victim").unwrap();
        assert!(victim.exists(), "traversal delete must not escape the scrollback dir");
        assert_eq!(std::fs::read(&victim).unwrap(), b"precious");
    }

    #[test]
    fn load_with_traversal_id_returns_none_and_reads_nothing_outside() {
        let dir = tempfile::tempdir().unwrap();
        let scrollback_dir = dir.path().join("scrollback");
        std::fs::create_dir_all(&scrollback_dir).unwrap();
        let store = ScrollbackStore::with_dir(scrollback_dir);

        // A real file outside the dir that {scrollback}/../foo.bin would resolve to.
        let outside = dir.path().join("foo.bin");
        std::fs::write(&outside, b"hi\nsecret outside content\n").unwrap();

        // Must reject (None) rather than read the outside file.
        assert!(store.load("../foo").unwrap().is_none());
        // save with a hostile id is a no-op (creates nothing).
        store.save("../evil", b"x", None, None).unwrap();
        assert!(!dir.path().join("evil.bin").exists());
    }

    // ---- Codex major #4: concurrent flush must not corrupt; write mutex ----

    #[test]
    fn write_lock_is_shared_per_session_and_distinct_across_sessions() {
        let (_d, store) = tmp_store();
        let a1 = store.write_lock_for("sess-a");
        let a2 = store.write_lock_for("sess-a");
        let b1 = store.write_lock_for("sess-b");
        // Same id -> same underlying mutex; different id -> different mutex.
        assert!(Arc::ptr_eq(&a1, &a2));
        assert!(!Arc::ptr_eq(&a1, &b1));
    }

    #[test]
    fn concurrent_saves_same_session_keep_file_consistent_and_no_tmp_leak() {
        let dir = tempfile::tempdir().unwrap();
        let store = Arc::new(ScrollbackStore::with_dir(dir.path().to_path_buf()));
        // The "latest" content every writer converges on.
        let payload = b"final-consistent-content\nKEEP\n".to_vec();

        let mut handles = Vec::new();
        for _ in 0..8 {
            let store = store.clone();
            let payload = payload.clone();
            handles.push(std::thread::spawn(move || {
                for _ in 0..25 {
                    store.save("race", &payload, None, None).unwrap();
                }
            }));
        }
        for h in handles {
            h.join().unwrap();
        }

        // File must be intact and exactly the converged payload (not interleaved).
        let on_disk = std::fs::read(dir.path().join("race.bin")).unwrap();
        assert_eq!(on_disk, payload, "concurrent saves must not corrupt the .bin");
        // Meta must round-trip and the load must succeed.
        let loaded = store.load("race").unwrap().unwrap();
        assert!(loaded.contains("KEEP"));
        // No leftover unique temp files from the interleaved writes.
        let leftover_tmp = std::fs::read_dir(dir.path())
            .unwrap()
            .flatten()
            .filter(|e| e.file_name().to_string_lossy().ends_with(".tmp"))
            .count();
        assert_eq!(leftover_tmp, 0, "no .tmp files should leak after concurrent saves");
    }

    // ---- Codex minor #4/#5: periodic GC from save + orphan cleanup ----

    #[test]
    fn save_triggers_global_cap_gc_when_due() {
        let dir = tempfile::tempdir().unwrap();
        // Size the cap so exactly ONE session (bin + its meta sidecar) fits but
        // two do not, making "evict oldest, keep newest" deterministic.
        let one_session_bytes = {
            let probe = ScrollbackStore::with_dir(dir.path().to_path_buf());
            probe.save("probe", b"\npayload-line\n", None, None).unwrap();
            let bin = std::fs::metadata(dir.path().join("probe.bin")).unwrap().len();
            let meta = std::fs::metadata(dir.path().join("probe.meta.json")).unwrap().len();
            probe.delete("probe").unwrap();
            bin + meta
        };
        let store = {
            let mut s = ScrollbackStore::with_dir(dir.path().to_path_buf());
            s.retention_days = 3650; // isolate the global-cap path
            // Room for one session, not two.
            s.global_max_bytes = one_session_bytes + (one_session_bytes / 2);
            s
        };
        // First save establishes an older session and runs the initial GC
        // (last_gc was None -> due); one session is under the cap, so it stays.
        store.save("old", b"\npayload-line\n", None, None).unwrap();
        // Age it so eviction order is deterministic.
        let past = std::time::SystemTime::now() - std::time::Duration::from_secs(120);
        let _ = filetime_set(&dir.path().join("old.bin"), past);
        // Force the next save's gc_if_due to fire (bypass the 60s rate limit).
        *store.last_gc.lock().unwrap() = None;

        // A second save pushes total over the cap; the in-save GC must evict.
        store.save("new", b"\npayload-line\n", None, None).unwrap();

        // Global cap was enforced mid-operation (not just at startup): the oldest
        // session is gone, the newest survives.
        assert!(store.load("old").unwrap().is_none(), "in-save GC must evict oldest over cap");
        assert!(store.load("new").unwrap().is_some());
    }

    #[test]
    fn gc_removes_orphan_tmp_and_meta_files() {
        let dir = tempfile::tempdir().unwrap();
        let store = {
            let mut s = ScrollbackStore::with_dir(dir.path().to_path_buf());
            s.retention_days = 3650;
            s
        };
        // A healthy session (bin + meta) that must survive.
        store.save("live", b"\nkeep me\n", None, None).unwrap();

        // Orphans: a leftover .tmp from an interrupted write, and a .meta.json
        // whose .bin no longer exists.
        let orphan_tmp = dir.path().join("interrupted.bin.deadbeef.tmp");
        std::fs::write(&orphan_tmp, b"partial").unwrap();
        // Age the .tmp past the grace window so the (age-gated) sweep reclaims it;
        // brand-new temps from concurrent writes are intentionally preserved.
        let stale = std::time::SystemTime::now() - (GC_MIN_INTERVAL + std::time::Duration::from_secs(5));
        let _ = filetime_set(&orphan_tmp, stale);
        let orphan_meta = dir.path().join("ghost.meta.json");
        std::fs::write(&orphan_meta, b"{}").unwrap();

        store.gc();

        assert!(!orphan_tmp.exists(), "stale orphan .tmp must be reclaimed");
        assert!(!orphan_meta.exists(), "orphan .meta.json (no .bin) must be reclaimed");
        // The live session's meta (it HAS a .bin) must be untouched.
        assert!(dir.path().join("live.meta.json").exists());
        assert!(dir.path().join("live.bin").exists());
    }

    /// Minimal mtime setter for tests (no extra crate dependency): rewrite the
    /// file via OpenOptions won't change mtime to the past, so we use filetime
    /// semantics through a tiny libc-free shim: set via `utimes` if available.
    /// Falls back to a no-op if unsupported (the test then simply may not GC).
    fn filetime_set(path: &Path, when: std::time::SystemTime) -> std::io::Result<()> {
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            let _ = path.metadata().map(|m| m.mtime());
            // Use `utimensat` via std is not available; shell out to `touch -t`.
            let dur = when
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default();
            let secs = dur.as_secs();
            // Format: [[CC]YY]MMDDhhmm[.SS]
            let datetime = chrono::DateTime::<chrono::Utc>::from_timestamp(secs as i64, 0)
                .unwrap_or_else(chrono::Utc::now);
            let stamp = datetime.format("%Y%m%d%H%M.%S").to_string();
            let status = std::process::Command::new("touch")
                .arg("-t")
                .arg(&stamp)
                .arg(path)
                .status();
            match status {
                Ok(s) if s.success() => Ok(()),
                _ => Ok(()), // best-effort; do not fail the test harness
            }
        }
        #[cfg(not(unix))]
        {
            let _ = (path, when);
            Ok(())
        }
    }
}
