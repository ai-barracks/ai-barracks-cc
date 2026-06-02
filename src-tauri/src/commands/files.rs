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

#[tauri::command]
pub fn save_rules(barrack_path: String, rules: RulesData) -> Result<(), String> {
    let mut content = String::from("# Rules\n\n## Must Always\n");
    for rule in &rules.must_always {
        content.push_str(&format!("- {}\n", rule));
    }
    content.push_str("\n## Must Never\n");
    for rule in &rules.must_never {
        content.push_str(&format!("- {}\n", rule));
    }
    content.push_str("\n## Learned\n");
    for rule in &rules.learned {
        content.push_str(&format!("- {}\n", rule));
    }

    // Route through the safe helper so RULES.md gets the same allowlist /
    // canonical / symlink-escape checks as write_barrack_file.
    write_barrack_file_impl(Path::new(&barrack_path), "RULES.md", &content)
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
