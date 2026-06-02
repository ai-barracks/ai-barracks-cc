use std::fs;
use std::path::{Path, PathBuf};
use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize)]
pub struct FileInfo {
    pub name: String,
    pub path: String,
    pub content: String,
    pub ownership: String,
    pub description: String,
    pub exists: bool,
}

/// Allowlisted filenames for `read_barrack_file` / `write_barrack_file`.
/// These are the only basenames that may be read/written via the barrack-file IPC.
const BARRACK_FILE_ALLOWLIST: &[&str] = &["GROWTH.md", "RULES.md", "SOUL.md", "agent.yaml"];

fn classify_ownership(filename: &str) -> (&'static str, &'static str) {
    match filename {
        "SOUL.md" => ("직접 편집", "에이전트의 이름, 전문성, 성격을 정의"),
        "GROWTH.md" => ("직접 편집", "에이전트 성장 트리거와 지식 기록 규칙"),
        "RULES.md" => ("자동 축적", "세션에서 학습한 행동 규칙 (에이전트가 자동 추가)"),
        "agent.yaml" => ("aib 관리", "배럭 메타데이터, 모델 설정, 버전 정보"),
        _ => ("시스템", ""),
    }
}

#[tauri::command]
pub fn get_barrack_files(barrack_path: String) -> Result<Vec<FileInfo>, String> {
    let base = PathBuf::from(&barrack_path);
    let filenames = ["GROWTH.md", "RULES.md", "SOUL.md", "agent.yaml"];

    let mut files = Vec::with_capacity(filenames.len());
    for name in filenames {
        let file_path = base.join(name);
        // symlink_metadata does not follow symlinks: an entry is "present"
        // even when it is a symlink whose target sits outside the barrack
        // (or is broken). exists() follows symlinks and is used only for
        // the user-visible `exists` flag.
        let path_entry_present = fs::symlink_metadata(&file_path).is_ok();
        let exists = file_path.exists();

        let content = if path_entry_present {
            // Route through the safe helper so an allowlisted basename
            // whose canonical target escapes the barrack root is rejected
            // instead of being silently read.
            read_barrack_file_impl(&base, name)?
        } else {
            String::new()
        };

        let (ownership, description) = classify_ownership(name);

        files.push(FileInfo {
            name: name.to_string(),
            path: file_path.to_string_lossy().to_string(),
            content,
            ownership: ownership.to_string(),
            description: description.to_string(),
            exists,
        });
    }

    Ok(files)
}

/// Reject any filename containing path separators, parent refs, leading dot,
/// drive prefixes (Windows), or which is absolute. Allowlist enforcement is
/// done separately by the caller — this helper is shared with the session
/// export validator.
fn validate_basename(filename: &str) -> Result<(), String> {
    if filename.is_empty() {
        return Err("filename is empty".into());
    }
    if filename.contains('/') || filename.contains('\\') {
        return Err("filename may not contain path separators".into());
    }
    if filename == "." || filename == ".." || filename.contains("..") {
        return Err("filename may not contain '..'".into());
    }
    if filename.starts_with('.') {
        return Err("filename may not start with '.'".into());
    }
    if Path::new(filename).is_absolute() {
        return Err("filename may not be absolute".into());
    }
    // Reject Windows drive prefixes defensively
    if filename.len() >= 2 && filename.as_bytes()[1] == b':' {
        return Err("filename may not contain a drive prefix".into());
    }
    Ok(())
}

/// Canonicalize an existing directory and return the resolved path. The path
/// must already exist; this resolves symlinks so that subsequent containment
/// checks operate against the real target.
fn canonical_dir(path: &Path) -> Result<PathBuf, String> {
    let canon = fs::canonicalize(path)
        .map_err(|e| format!("디렉터리 정규화 실패: {}", e))?;
    if !canon.is_dir() {
        return Err(format!("경로가 디렉터리가 아닙니다: {}", canon.display()));
    }
    Ok(canon)
}

pub fn read_barrack_file_impl(barrack: &Path, filename: &str) -> Result<String, String> {
    if !BARRACK_FILE_ALLOWLIST.contains(&filename) {
        return Err(format!("허용되지 않은 파일: {}", filename));
    }
    // Defense-in-depth: allowlist entries are literals without separators,
    // but re-validate in case the allowlist is ever extended.
    validate_basename(filename)?;

    let root = canonical_dir(barrack)?;
    let target = root.join(filename);

    // Detect any present entry — including a symlink whose target does not
    // exist — without following symlinks. exists() follows symlinks and
    // would miss a broken symlink that fs::read_to_string would then resolve
    // to an outside path.
    if fs::symlink_metadata(&target).is_ok() {
        let canon_target = fs::canonicalize(&target)
            .map_err(|e| format!("파일 정규화 실패: {}", e))?;
        if !canon_target.starts_with(&root) {
            return Err("경로가 배럭 루트를 벗어남".into());
        }
    }

    fs::read_to_string(&target).map_err(|e| format!("파일 읽기 실패: {}", e))
}

pub fn write_barrack_file_impl(
    barrack: &Path,
    filename: &str,
    content: &str,
) -> Result<(), String> {
    if !BARRACK_FILE_ALLOWLIST.contains(&filename) {
        return Err(format!("허용되지 않은 파일: {}", filename));
    }
    validate_basename(filename)?;

    let root = canonical_dir(barrack)?;
    let target = root.join(filename);

    // Detect any present entry without following symlinks. A symlink whose
    // target does not yet exist returns exists() == false on Unix, so a
    // naive exists() check would let fs::write follow the symlink and
    // create the outside file. symlink_metadata catches that case; we then
    // require canonicalize to succeed and resolve inside the barrack root.
    if fs::symlink_metadata(&target).is_ok() {
        let canon_target = fs::canonicalize(&target)
            .map_err(|e| format!("파일 정규화 실패: {}", e))?;
        if !canon_target.starts_with(&root) {
            return Err("경로가 배럭 루트를 벗어남".into());
        }
    }

    fs::write(&target, content).map_err(|e| format!("파일 쓰기 실패: {}", e))
}

#[tauri::command]
pub fn read_barrack_file(barrack_path: String, filename: String) -> Result<String, String> {
    read_barrack_file_impl(Path::new(&barrack_path), &filename)
}

#[tauri::command]
pub fn write_barrack_file(
    barrack_path: String,
    filename: String,
    content: String,
) -> Result<(), String> {
    write_barrack_file_impl(Path::new(&barrack_path), &filename, &content)
}

pub fn write_session_export_impl(
    barrack: &Path,
    filename: &str,
    content: &str,
) -> Result<(), String> {
    validate_basename(filename)?;
    if !filename.ends_with(".txt") {
        return Err("session export 파일은 .txt 확장자여야 합니다".into());
    }

    let root = canonical_dir(barrack)?;
    let sessions_dir = root.join("sessions");
    fs::create_dir_all(&sessions_dir)
        .map_err(|e| format!("sessions 디렉터리 생성 실패: {}", e))?;
    let canon_sessions = canonical_dir(&sessions_dir)?;
    if !canon_sessions.starts_with(&root) {
        return Err("sessions 디렉터리가 배럭 루트를 벗어남".into());
    }

    let target = canon_sessions.join(filename);
    // symlink_metadata catches a present entry even when it is a symlink
    // whose target does not yet exist — without this, fs::write would
    // follow the symlink and create the outside file. canonicalize must
    // succeed and resolve to a path under canon_sessions.
    if fs::symlink_metadata(&target).is_ok() {
        let canon_target = fs::canonicalize(&target)
            .map_err(|e| format!("파일 정규화 실패: {}", e))?;
        if !canon_target.starts_with(&canon_sessions) {
            return Err("경로가 sessions 디렉터리를 벗어남".into());
        }
    }
    // Even when target doesn't exist, verify its parent is exactly the canonical sessions dir.
    if let Some(parent) = target.parent() {
        let canon_parent = fs::canonicalize(parent)
            .map_err(|e| format!("부모 디렉터리 정규화 실패: {}", e))?;
        if canon_parent != canon_sessions {
            return Err("경로가 sessions 디렉터리를 벗어남".into());
        }
    } else {
        return Err("대상 경로의 부모가 없습니다".into());
    }

    fs::write(&target, content).map_err(|e| format!("파일 쓰기 실패: {}", e))
}

#[tauri::command]
pub fn write_session_export(
    barrack_path: String,
    filename: String,
    content: String,
) -> Result<(), String> {
    write_session_export_impl(Path::new(&barrack_path), &filename, &content)
}

#[derive(Debug, Serialize, Deserialize)]
pub struct RulesData {
    pub must_always: Vec<String>,
    pub must_never: Vec<String>,
    pub learned: Vec<String>,
}

#[tauri::command]
pub fn get_rules(barrack_path: String) -> Result<RulesData, String> {
    let barrack = Path::new(&barrack_path);
    // Route through the safe helper so RULES.md gets the same allowlist /
    // canonical / symlink-escape checks as read_barrack_file. Missing file is
    // not an error: we just return empty rules.
    let content = if barrack.join("RULES.md").exists() {
        read_barrack_file_impl(barrack, "RULES.md")?
    } else {
        String::new()
    };

    let mut data = RulesData {
        must_always: Vec::new(),
        must_never: Vec::new(),
        learned: Vec::new(),
    };
    let mut current = "";

    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("## Must Always") {
            current = "must_always";
        } else if trimmed.starts_with("## Must Never") {
            current = "must_never";
        } else if trimmed.starts_with("## Learned") {
            current = "learned";
        } else if trimmed.starts_with("## ") {
            current = "";
        } else if let Some(item) = trimmed.strip_prefix("- ") {
            match current {
                "must_always" => data.must_always.push(item.to_string()),
                "must_never" => data.must_never.push(item.to_string()),
                "learned" => data.learned.push(item.to_string()),
                _ => {}
            }
        }
    }

    Ok(data)
}

/// Minimal RULES.md template used when the file is missing or empty. Must
/// match the frontend `emptyRulesTemplate()` so a save from a fresh barrack
/// produces the same shape as a save from the UI.
const RULES_TEMPLATE: &str =
    "# Rules\n\n## Must Always\n\n## Must Never\n\n## Learned\n";

#[tauri::command]
pub fn save_rules(barrack_path: String, rules: RulesData) -> Result<(), String> {
    let barrack = Path::new(&barrack_path);

    // Read existing raw if present so we can patch the managed bullet runs
    // without dropping comments, custom sections, or ownership markers. The
    // safe helper still enforces the allowlist / symlink-escape checks.
    let raw = if barrack.join("RULES.md").exists() {
        read_barrack_file_impl(barrack, "RULES.md")?
    } else {
        String::new()
    };

    let patched = patch_rules_raw(&raw, &rules)?;
    write_barrack_file_impl(barrack, "RULES.md", &patched)
}

fn patch_rules_raw(raw: &str, next: &RulesData) -> Result<String, String> {
    let effective_raw: &str = if raw.is_empty() { RULES_TEMPLATE } else { raw };
    let prev = parse_rules_raw(effective_raw);
    let mut current = effective_raw.to_string();

    for spec in [
        (RulesField::MustAlways, "Must Always"),
        (RulesField::MustNever, "Must Never"),
        (RulesField::Learned, "Learned"),
    ] {
        let (field, heading) = spec;
        let (old_list, new_list) = match field {
            RulesField::MustAlways => (&prev.must_always, &next.must_always),
            RulesField::MustNever => (&prev.must_never, &next.must_never),
            RulesField::Learned => (&prev.learned, &next.learned),
        };
        if old_list == new_list {
            continue;
        }
        current = patch_list_section(&current, field, heading, old_list, new_list)?;
    }

    Ok(current)
}

#[derive(Clone, Copy, Debug)]
enum RulesField {
    MustAlways,
    MustNever,
    Learned,
}

impl RulesField {
    fn as_str(self) -> &'static str {
        match self {
            RulesField::MustAlways => "must_always",
            RulesField::MustNever => "must_never",
            RulesField::Learned => "learned",
        }
    }
}

fn parse_rules_raw(raw: &str) -> RulesData {
    let mut data = RulesData {
        must_always: Vec::new(),
        must_never: Vec::new(),
        learned: Vec::new(),
    };
    let sections = split_markdown_sections(raw);
    for section in &sections {
        if section.level != 2 {
            continue;
        }
        let h = match &section.heading {
            Some(h) => h.as_str(),
            None => continue,
        };
        let bullets = extract_managed_bullets(&section.raw);
        match h {
            "Must Always" => data.must_always = bullets,
            "Must Never" => data.must_never = bullets,
            "Learned" => data.learned = bullets,
            _ => {}
        }
    }
    data
}

#[derive(Debug, Clone)]
struct MdSection {
    level: usize,
    heading: Option<String>,
    raw: String,
}

fn split_markdown_sections(raw: &str) -> Vec<MdSection> {
    let lines = split_lines_keep_eol(raw);
    let mut sections: Vec<MdSection> = Vec::new();
    let mut level = 0usize;
    let mut heading: Option<String> = None;
    let mut buf = String::new();
    let mut fence = FenceState::new();

    for line in &lines {
        let content = strip_eol(line);
        fence.consume(content);
        // Heading match only when we are NOT inside a fence after this line's
        // fence toggle, mirroring the TS reference in documentPatch.ts. A
        // fence marker line itself starts with `` ` `` or `~` so it cannot
        // match the ATX heading regex either way.
        let heading_match = if !fence.inside() {
            match_atx_heading(content)
        } else {
            None
        };

        if let Some((lvl, hdg)) = heading_match {
            sections.push(MdSection {
                level,
                heading: heading.clone(),
                raw: std::mem::take(&mut buf),
            });
            level = lvl;
            heading = Some(hdg);
            buf.push_str(line);
        } else {
            buf.push_str(line);
        }
    }
    sections.push(MdSection {
        level,
        heading,
        raw: buf,
    });
    sections
}

fn extract_managed_bullets(section_raw: &str) -> Vec<String> {
    let lines = split_lines_keep_eol(section_raw);
    let mut out = Vec::new();
    let mut fence = FenceState::new();
    for line in lines.iter().skip(1) {
        let content = strip_eol(line);
        if fence.consume(content) {
            continue;
        }
        if fence.inside() {
            continue;
        }
        if let Some(rest) = match_bullet(content) {
            out.push(rest.to_string());
        }
    }
    out
}

fn patch_list_section(
    raw: &str,
    field: RulesField,
    heading: &str,
    old_list: &[String],
    new_list: &[String],
) -> Result<String, String> {
    let sections = split_markdown_sections(raw);
    let mut matching: Vec<usize> = Vec::new();
    for (i, s) in sections.iter().enumerate() {
        if s.level == 2 && s.heading.as_deref() == Some(heading) {
            matching.push(i);
        }
    }
    if matching.is_empty() {
        return Err(format!(
            "RULES.md patch 실패: section-not-found ({})",
            field.as_str()
        ));
    }
    if matching.len() > 1 {
        return Err(format!(
            "RULES.md patch 실패: multiple-sections ({})",
            field.as_str()
        ));
    }
    let idx = matching[0];
    let section = &sections[idx];
    let lines = split_lines_keep_eol(&section.raw);
    let runs = find_bullet_runs(&lines, 1);
    if runs.len() > 1 {
        return Err(format!(
            "RULES.md patch 실패: multiple-bullet-runs ({})",
            field.as_str()
        ));
    }

    let new_section_raw = if runs.len() == 1 {
        let run = runs[0];
        let style = detect_bullet_style(lines[run.start]).ok_or_else(|| {
            format!(
                "RULES.md patch 실패: multiple-bullet-runs ({})",
                field.as_str()
            )
        })?;
        let mut run_eol: Option<&str> = None;
        for line in &lines[run.start..run.end] {
            if let Some(e) = detect_line_eol(line) {
                run_eol = Some(e);
                break;
            }
        }
        let eol = run_eol.unwrap_or_else(|| detect_eol(raw));
        let last_has_eol = has_eol(lines[run.end - 1]);

        let mut new_section = String::new();
        for l in &lines[..run.start] {
            new_section.push_str(l);
        }
        let n = new_list.len();
        for (k, b) in new_list.iter().enumerate() {
            let is_last = k + 1 == n;
            let use_eol = if is_last && !last_has_eol { "" } else { eol };
            new_section.push_str(&style.indent);
            new_section.push_str(&style.marker);
            new_section.push_str(b);
            new_section.push_str(use_eol);
        }
        for l in &lines[run.end..] {
            new_section.push_str(l);
        }
        new_section
    } else {
        // 0 runs
        if !old_list.is_empty() {
            return Err(format!(
                "RULES.md patch 실패: multiple-bullet-runs ({})",
                field.as_str()
            ));
        }
        if new_list.is_empty() {
            return Ok(raw.to_string());
        }
        let eol = detect_eol(raw);
        let heading_line: &str = lines.first().copied().unwrap_or("");
        let heading_has_eol = detect_line_eol(heading_line).is_some();
        let mut new_section = String::new();
        new_section.push_str(heading_line);
        if !heading_has_eol {
            new_section.push_str(eol);
        }
        for b in new_list {
            new_section.push_str("- ");
            new_section.push_str(b);
            new_section.push_str(eol);
        }
        for l in lines.iter().skip(1) {
            new_section.push_str(l);
        }
        new_section
    };

    let mut out = String::new();
    for (i, s) in sections.iter().enumerate() {
        if i == idx {
            out.push_str(&new_section_raw);
        } else {
            out.push_str(&s.raw);
        }
    }
    Ok(out)
}

#[derive(Clone, Copy, Debug)]
struct BulletRun {
    start: usize,
    end: usize,
}

fn find_bullet_runs(lines: &[&str], start_idx: usize) -> Vec<BulletRun> {
    let mut runs = Vec::new();
    let mut fence = FenceState::new();
    let mut i = start_idx;
    while i < lines.len() {
        let content = strip_eol(lines[i]);
        if fence.consume(content) {
            i += 1;
            continue;
        }
        if fence.inside() {
            i += 1;
            continue;
        }
        if match_bullet(content).is_some() {
            let mut j = i + 1;
            while j < lines.len() && match_bullet(strip_eol(lines[j])).is_some() {
                j += 1;
            }
            runs.push(BulletRun { start: i, end: j });
            i = j;
        } else {
            i += 1;
        }
    }
    runs
}

struct BulletStyle {
    indent: String,
    marker: String,
}

fn detect_bullet_style(line: &str) -> Option<BulletStyle> {
    let content = strip_eol(line);
    let bytes = content.as_bytes();
    let mut i = 0;
    while i < bytes.len() && (bytes[i] == b' ' || bytes[i] == b'\t') {
        i += 1;
    }
    if i >= bytes.len() {
        return None;
    }
    let marker_byte = bytes[i];
    if marker_byte != b'-' && marker_byte != b'*' && marker_byte != b'+' {
        return None;
    }
    let marker_start = i;
    i += 1;
    let mut saw_ws = false;
    while i < bytes.len() && (bytes[i] == b' ' || bytes[i] == b'\t') {
        saw_ws = true;
        i += 1;
    }
    if !saw_ws {
        return None;
    }
    let indent = content[..marker_start].to_string();
    let marker = content[marker_start..i].to_string();
    Some(BulletStyle { indent, marker })
}

fn match_bullet(content: &str) -> Option<&str> {
    let bytes = content.as_bytes();
    let mut i = 0;
    while i < bytes.len() && (bytes[i] == b' ' || bytes[i] == b'\t') {
        i += 1;
    }
    if i >= bytes.len() {
        return None;
    }
    let m = bytes[i];
    if m != b'-' && m != b'*' && m != b'+' {
        return None;
    }
    i += 1;
    let mut saw_ws = false;
    while i < bytes.len() && (bytes[i] == b' ' || bytes[i] == b'\t') {
        saw_ws = true;
        i += 1;
    }
    if !saw_ws {
        return None;
    }
    Some(&content[i..])
}

fn match_atx_heading(content: &str) -> Option<(usize, String)> {
    let bytes = content.as_bytes();
    let mut i = 0;
    let mut hashes = 0;
    while i < bytes.len() && bytes[i] == b'#' && hashes < 7 {
        i += 1;
        hashes += 1;
    }
    if hashes == 0 || hashes > 6 {
        return None;
    }
    if i >= bytes.len() {
        return None;
    }
    if bytes[i] != b' ' && bytes[i] != b'\t' {
        return None;
    }
    while i < bytes.len() && (bytes[i] == b' ' || bytes[i] == b'\t') {
        i += 1;
    }
    let rest = &content[i..];
    if rest.is_empty() {
        return None;
    }
    // Strip optional trailing whitespace + `#+` sequence.
    let trimmed_end = rest.trim_end_matches([' ', '\t']);
    let stripped: &str = if let Some(idx) = trimmed_end.rfind([' ', '\t']) {
        let tail = &trimmed_end[idx + 1..];
        if !tail.is_empty() && tail.chars().all(|c| c == '#') {
            trimmed_end[..idx].trim_end_matches([' ', '\t'])
        } else {
            trimmed_end
        }
    } else {
        trimmed_end
    };
    let heading = stripped.trim().to_string();
    if heading.is_empty() {
        return None;
    }
    Some((hashes, heading))
}

fn split_lines_keep_eol(raw: &str) -> Vec<&str> {
    let bytes = raw.as_bytes();
    let mut out = Vec::new();
    let mut start = 0usize;
    let mut i = 0usize;
    while i < bytes.len() {
        if bytes[i] == b'\n' {
            let end = i + 1;
            out.push(&raw[start..end]);
            start = end;
            i = end;
        } else {
            i += 1;
        }
    }
    if start < bytes.len() {
        out.push(&raw[start..]);
    }
    out
}

fn strip_eol(line: &str) -> &str {
    if let Some(s) = line.strip_suffix("\r\n") {
        return s;
    }
    if let Some(s) = line.strip_suffix('\n') {
        return s;
    }
    line
}

fn detect_line_eol(line: &str) -> Option<&'static str> {
    if line.ends_with("\r\n") {
        Some("\r\n")
    } else if line.ends_with('\n') {
        Some("\n")
    } else {
        None
    }
}

fn has_eol(line: &str) -> bool {
    line.ends_with('\n')
}

fn detect_eol(raw: &str) -> &'static str {
    let mut crlf = 0usize;
    let mut lf = 0usize;
    let bytes = raw.as_bytes();
    let mut i = 0usize;
    while i < bytes.len() {
        if bytes[i] == b'\n' {
            if i > 0 && bytes[i - 1] == b'\r' {
                crlf += 1;
            } else {
                lf += 1;
            }
        }
        i += 1;
    }
    if crlf > lf {
        "\r\n"
    } else {
        "\n"
    }
}

struct FenceState {
    inside: bool,
    ch: Option<u8>,
    len: usize,
}

impl FenceState {
    fn new() -> Self {
        Self {
            inside: false,
            ch: None,
            len: 0,
        }
    }
    fn inside(&self) -> bool {
        self.inside
    }
    /// Returns true when this line is a fence marker (open or close).
    fn consume(&mut self, content: &str) -> bool {
        let bytes = content.as_bytes();
        let mut i = 0usize;
        let mut spaces = 0usize;
        while i < bytes.len() && bytes[i] == b' ' && spaces < 3 {
            i += 1;
            spaces += 1;
        }
        if i >= bytes.len() {
            return false;
        }
        let ch = bytes[i];
        if ch != b'`' && ch != b'~' {
            return false;
        }
        let start = i;
        while i < bytes.len() && bytes[i] == ch {
            i += 1;
        }
        let len = i - start;
        if len < 3 {
            return false;
        }
        if !self.inside {
            self.inside = true;
            self.ch = Some(ch);
            self.len = len;
        } else if self.ch == Some(ch) && len >= self.len {
            self.inside = false;
            self.ch = None;
            self.len = 0;
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs as test_fs;
    use tempfile::TempDir;

    fn make_barrack() -> TempDir {
        TempDir::new().expect("tempdir")
    }

    #[test]
    fn allowlisted_files_round_trip() {
        let tmp = make_barrack();
        let root = tmp.path();
        for name in ["GROWTH.md", "RULES.md", "SOUL.md", "agent.yaml"] {
            let payload = format!("content of {}", name);
            write_barrack_file_impl(root, name, &payload).expect("write should succeed");
            let read = read_barrack_file_impl(root, name).expect("read should succeed");
            assert_eq!(read, payload, "round-trip mismatch for {}", name);
        }
    }

    #[test]
    fn rejects_non_allowlisted_filename() {
        let tmp = make_barrack();
        let err = write_barrack_file_impl(tmp.path(), "secrets.env", "x")
            .expect_err("must reject non-allowlisted name");
        assert!(err.contains("허용되지 않은"), "got: {}", err);

        let err = read_barrack_file_impl(tmp.path(), "secrets.env")
            .expect_err("must reject non-allowlisted name");
        assert!(err.contains("허용되지 않은"), "got: {}", err);
    }

    #[test]
    fn rejects_dotdot_in_filename() {
        let tmp = make_barrack();
        // The allowlist check fires first; either way the call must fail.
        let err = read_barrack_file_impl(tmp.path(), "../agent.yaml")
            .expect_err("must reject .. traversal");
        assert!(!err.is_empty());

        let err = write_barrack_file_impl(tmp.path(), "../agent.yaml", "x")
            .expect_err("must reject .. traversal");
        assert!(!err.is_empty());
    }

    #[test]
    fn rejects_path_separator_in_filename() {
        let tmp = make_barrack();
        let err = write_barrack_file_impl(tmp.path(), "sub/agent.yaml", "x")
            .expect_err("must reject path separator");
        assert!(!err.is_empty());
        let err = write_barrack_file_impl(tmp.path(), "sub\\agent.yaml", "x")
            .expect_err("must reject backslash separator");
        assert!(!err.is_empty());
    }

    #[test]
    fn arbitrary_absolute_path_no_longer_possible() {
        // Surface invariant: the safe API takes only (barrack_path, allowlisted basename).
        // Passing an arbitrary absolute path as the filename is rejected because
        // (a) it's not in the allowlist and (b) it fails basename validation.
        let tmp = make_barrack();
        let outside = make_barrack();
        let outside_target = outside.path().join("poc");
        let outside_target_str = outside_target
            .to_str()
            .expect("tempdir path must be UTF-8 for this test");

        let err = write_barrack_file_impl(tmp.path(), outside_target_str, "pwn")
            .expect_err("absolute paths must be rejected");
        assert!(!err.is_empty());
        assert!(
            !outside_target.exists(),
            "must not have written to {}",
            outside_target.display()
        );

        let err = read_barrack_file_impl(tmp.path(), outside_target_str)
            .expect_err("absolute paths must be rejected");
        assert!(!err.is_empty());
    }

    #[test]
    fn write_creates_file_inside_canonical_root() {
        let tmp = make_barrack();
        write_barrack_file_impl(tmp.path(), "agent.yaml", "v: 1").unwrap();
        let written = test_fs::read_to_string(tmp.path().join("agent.yaml")).unwrap();
        assert_eq!(written, "v: 1");
    }

    #[test]
    fn get_barrack_files_rejects_symlink_escape() {
        // get_barrack_files must route per-file reads through the safe helper,
        // so an allowlisted basename that symlinks outside the barrack root is
        // rejected — the command must NOT return outside content.
        #[cfg(unix)]
        {
            use std::os::unix::fs::symlink;
            let outside = make_barrack();
            let outside_file = outside.path().join("evil.md");
            test_fs::write(&outside_file, "outside_secret").unwrap();

            let barrack = make_barrack();
            symlink(&outside_file, barrack.path().join("GROWTH.md")).unwrap();

            let err = get_barrack_files(barrack.path().to_string_lossy().to_string())
                .expect_err("get_barrack_files must reject symlink escape");
            assert!(err.contains("배럭 루트"), "got: {}", err);
        }
    }

    #[test]
    fn rejects_symlink_escape_for_read() {
        // Place a symlink at <barrack>/GROWTH.md that points outside the barrack.
        // canonical_target.starts_with(canonical_root) must be false → error.
        #[cfg(unix)]
        {
            use std::os::unix::fs::symlink;
            let outside = make_barrack();
            let outside_file = outside.path().join("evil.md");
            test_fs::write(&outside_file, "secret").unwrap();

            let barrack = make_barrack();
            let inside_link = barrack.path().join("GROWTH.md");
            symlink(&outside_file, &inside_link).unwrap();

            let err = read_barrack_file_impl(barrack.path(), "GROWTH.md")
                .expect_err("symlink escape must be rejected");
            assert!(err.contains("배럭 루트"), "got: {}", err);
        }
    }

    #[test]
    fn save_rules_rejects_rules_md_symlink_escape() {
        // save_rules / get_rules must now route through the safe helpers, so a
        // RULES.md symlink pointing outside the barrack must be rejected and
        // the outside file must not be written.
        #[cfg(unix)]
        {
            use std::os::unix::fs::symlink;
            let outside = make_barrack();
            let outside_file = outside.path().join("evil.md");
            test_fs::write(&outside_file, "untouched").unwrap();

            let barrack = make_barrack();
            symlink(&outside_file, barrack.path().join("RULES.md")).unwrap();

            let rules = RulesData {
                must_always: vec!["pwned".to_string()],
                must_never: vec![],
                learned: vec![],
            };
            let err = save_rules(
                barrack.path().to_string_lossy().to_string(),
                rules,
            )
            .expect_err("save_rules must reject RULES.md symlink escape");
            assert!(err.contains("배럭 루트"), "got: {}", err);

            // The outside file must remain unchanged.
            let after = test_fs::read_to_string(&outside_file).unwrap();
            assert_eq!(after, "untouched");

            // get_rules must also surface the symlink escape error.
            let err = get_rules(barrack.path().to_string_lossy().to_string())
                .expect_err("get_rules must reject RULES.md symlink escape");
            assert!(err.contains("배럭 루트"), "got: {}", err);
        }
    }

    #[test]
    fn save_rules_writes_rules_md_inside_barrack() {
        // Happy path: save_rules round-trips through the safe helpers and the
        // file lands at <barrack>/RULES.md.
        let tmp = make_barrack();
        let rules = RulesData {
            must_always: vec!["a1".into()],
            must_never: vec!["n1".into()],
            learned: vec!["l1".into()],
        };
        save_rules(tmp.path().to_string_lossy().to_string(), rules).unwrap();
        let written = test_fs::read_to_string(tmp.path().join("RULES.md")).unwrap();
        assert!(written.contains("- a1"));
        assert!(written.contains("- n1"));
        assert!(written.contains("- l1"));

        let parsed = get_rules(tmp.path().to_string_lossy().to_string()).unwrap();
        assert_eq!(parsed.must_always, vec!["a1".to_string()]);
        assert_eq!(parsed.must_never, vec!["n1".to_string()]);
        assert_eq!(parsed.learned, vec!["l1".to_string()]);
    }

    #[test]
    fn save_rules_preserves_unknown_section_and_unrelated_managed_lists() {
        // Regression: when RULES.md already exists, save_rules must patch only
        // the changed managed bullet runs and leave comments, unknown sections,
        // and unrelated managed sections byte-identical.
        let tmp = make_barrack();
        let original = "\
<!-- AIB:RULES:v1 -->
# Rules

preamble prose

## Must Always
<!-- pinned by ops -->
- communicate in Korean
- write tests

## Must Never
- skip code review
- bypass hooks

## Learned
- log before mutating shared state

## Notes
custom section content
```python
- not a managed bullet
```

<!-- AIB:RULES:END -->
";
        test_fs::write(tmp.path().join("RULES.md"), original).unwrap();

        // Only modify must_always; leave must_never and learned at their
        // current parsed values.
        let parsed = get_rules(tmp.path().to_string_lossy().to_string()).unwrap();
        let next = RulesData {
            must_always: vec![
                "communicate in Korean".into(),
                "write tests".into(),
                "use timezones".into(),
            ],
            must_never: parsed.must_never.clone(),
            learned: parsed.learned.clone(),
        };
        save_rules(tmp.path().to_string_lossy().to_string(), next).unwrap();
        let written = test_fs::read_to_string(tmp.path().join("RULES.md")).unwrap();

        // Managed change landed exactly inside the Must Always section,
        // keeping the in-section comment.
        assert!(
            written.contains(
                "## Must Always\n<!-- pinned by ops -->\n- communicate in Korean\n- write tests\n- use timezones\n"
            ),
            "must_always not patched in place: {}",
            written
        );
        // Unrelated managed sections are byte-identical.
        assert!(written.contains("## Must Never\n- skip code review\n- bypass hooks\n"));
        assert!(written.contains("## Learned\n- log before mutating shared state\n"));
        // Comments / preamble / unknown section / fenced code / end marker preserved.
        assert!(written.contains("<!-- AIB:RULES:v1 -->"));
        assert!(written.contains("preamble prose"));
        assert!(written.contains(
            "## Notes\ncustom section content\n```python\n- not a managed bullet\n```"
        ));
        assert!(written.contains("<!-- AIB:RULES:END -->"));
    }

    #[test]
    fn save_rules_no_op_is_byte_identical() {
        // When the supplied RulesData matches the parsed-from-raw values,
        // save_rules must not change any byte of RULES.md.
        let tmp = make_barrack();
        let original = "\
# Rules

## Must Always
<!-- keep this -->
- a1

## Must Never
- n1

## Learned
- l1

## Custom
custom prose
";
        test_fs::write(tmp.path().join("RULES.md"), original).unwrap();

        let parsed = get_rules(tmp.path().to_string_lossy().to_string()).unwrap();
        save_rules(tmp.path().to_string_lossy().to_string(), parsed).unwrap();
        let written = test_fs::read_to_string(tmp.path().join("RULES.md")).unwrap();
        assert_eq!(written, original);
    }

    #[test]
    fn get_rules_returns_empty_when_missing() {
        // Missing RULES.md must not error — it just means no rules yet.
        let tmp = make_barrack();
        let parsed = get_rules(tmp.path().to_string_lossy().to_string()).unwrap();
        assert!(parsed.must_always.is_empty());
        assert!(parsed.must_never.is_empty());
        assert!(parsed.learned.is_empty());
    }

    #[test]
    fn terminal_export_writes_under_sessions() {
        let tmp = make_barrack();
        write_session_export_impl(tmp.path(), "terminal-x-2026-01-01.txt", "buf").unwrap();
        let written = test_fs::read_to_string(
            tmp.path().join("sessions").join("terminal-x-2026-01-01.txt"),
        )
        .unwrap();
        assert_eq!(written, "buf");
    }

    #[test]
    fn terminal_export_rejects_traversal() {
        let tmp = make_barrack();
        let err = write_session_export_impl(tmp.path(), "../escape.txt", "x")
            .expect_err("dotdot must be rejected");
        assert!(!err.is_empty());
        let err = write_session_export_impl(tmp.path(), "sub/escape.txt", "x")
            .expect_err("path separator must be rejected");
        assert!(!err.is_empty());

        let outside = make_barrack();
        let outside_target = outside.path().join("poc.txt");
        let outside_target_str = outside_target
            .to_str()
            .expect("tempdir path must be UTF-8 for this test");
        let err = write_session_export_impl(tmp.path(), outside_target_str, "x")
            .expect_err("absolute path must be rejected");
        assert!(!err.is_empty());
        assert!(
            !outside_target.exists(),
            "must not have written to {}",
            outside_target.display()
        );
    }

    #[test]
    fn terminal_export_requires_txt_extension() {
        let tmp = make_barrack();
        let err = write_session_export_impl(tmp.path(), "terminal-x.md", "x")
            .expect_err(".md must be rejected");
        assert!(err.contains(".txt"), "got: {}", err);
        let err = write_session_export_impl(tmp.path(), ".txt", "x")
            .expect_err("empty basename must be rejected");
        assert!(!err.is_empty());
    }

    #[test]
    fn write_barrack_file_rejects_broken_symlink_to_outside() {
        // A symlink at an allowlisted basename whose target does NOT yet
        // exist must be rejected without creating the outside file. exists()
        // would return false for the broken symlink and let fs::write follow
        // it; symlink_metadata + canonicalize closes that hole.
        #[cfg(unix)]
        {
            use std::os::unix::fs::symlink;
            let outside = make_barrack();
            let outside_target = outside.path().join("not-yet-here.md");
            assert!(!outside_target.exists(), "precondition: target must not exist");

            let barrack = make_barrack();
            symlink(&outside_target, barrack.path().join("RULES.md")).unwrap();

            let err = write_barrack_file_impl(barrack.path(), "RULES.md", "pwn")
                .expect_err("broken-symlink escape must be rejected");
            assert!(!err.is_empty(), "got empty error");
            assert!(
                !outside_target.exists(),
                "must not have created {}",
                outside_target.display()
            );
        }
    }

    #[test]
    fn write_session_export_rejects_broken_symlink_to_outside() {
        // Same broken-symlink escape, but for the session export sink:
        // <barrack>/sessions/<filename>.txt is a symlink to a non-existent
        // outside path. fs::write must not follow it.
        #[cfg(unix)]
        {
            use std::os::unix::fs::symlink;
            let outside = make_barrack();
            let outside_target = outside.path().join("not-yet-here.txt");
            assert!(!outside_target.exists(), "precondition: target must not exist");

            let barrack = make_barrack();
            test_fs::create_dir_all(barrack.path().join("sessions")).unwrap();
            let link_path = barrack.path().join("sessions").join("export.txt");
            symlink(&outside_target, &link_path).unwrap();

            let err = write_session_export_impl(barrack.path(), "export.txt", "pwn")
                .expect_err("broken-symlink escape must be rejected");
            assert!(!err.is_empty(), "got empty error");
            assert!(
                !outside_target.exists(),
                "must not have created {}",
                outside_target.display()
            );
        }
    }

    #[test]
    fn terminal_export_rejects_symlink_sessions_escape() {
        #[cfg(unix)]
        {
            use std::os::unix::fs::symlink;
            let outside = make_barrack();
            let barrack = make_barrack();
            // Replace sessions/ with a symlink to outside dir → canonical sessions
            // would land outside the barrack root and must be rejected.
            symlink(outside.path(), barrack.path().join("sessions")).unwrap();
            let err = write_session_export_impl(barrack.path(), "x.txt", "y")
                .expect_err("symlink escape on sessions/ must be rejected");
            assert!(err.contains("sessions"), "got: {}", err);
        }
    }
}
