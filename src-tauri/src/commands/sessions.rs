use regex::Regex;
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Serialize, Clone)]
pub struct SessionInfo {
    pub id: String,
    pub client: String,
    pub started: String,
    pub ended: String,
    pub status: String,
    pub task: String,
    pub continues: String,
}

#[derive(Debug, Serialize, Clone)]
pub struct SessionDetail {
    pub info: SessionInfo,
    pub log: Vec<String>,
    pub decisions: Vec<String>,
    pub blockers: Vec<String>,
    pub wiki_extractions: Vec<String>,
    pub identity_suggestions: Vec<String>,
    pub raw_content: String,
    /// "unsealed" | "intact" | "modified" | "invalid" — see `seal_status`.
    pub seal_status: String,
}

fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{:02x}", b))
        .collect()
}

/// Compare an ended session file against the seal `aib` writes at SessionEnd:
/// `sessions/.seals/<id>.sha256` = one `shasum -a 256` line "<hex>  sessions/<id>.md".
/// A seal that exists but cannot be read or parsed is "invalid", never "unsealed",
/// so breaking the seal file does not hide a change.
fn seal_status(barrack: &Path, session_id: &str, file_bytes: &[u8]) -> &'static str {
    let seal_path = barrack
        .join("sessions")
        .join(".seals")
        .join(format!("{}.sha256", session_id));
    let Ok(meta) = fs::symlink_metadata(&seal_path) else {
        return "unsealed";
    };
    if meta.file_type().is_symlink() {
        return "invalid";
    }
    let Ok(content) = fs::read_to_string(&seal_path) else {
        return "invalid";
    };
    let record = content.trim_end_matches('\n');
    let expected_path = format!("sessions/{}.md", session_id);
    let sealed_hex = match record.split_once("  ") {
        Some((hex, path))
            if !record.contains('\n')
                && hex.len() == 64
                && hex.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
                && path == expected_path =>
        {
            hex
        }
        _ => return "invalid",
    };
    if sealed_hex == sha256_hex(file_bytes) {
        "intact"
    } else {
        "modified"
    }
}

fn parse_field(content: &str, field: &str) -> String {
    let pattern = format!(r"\*\*{}\*\*:\s*(.+)", regex::escape(field));
    Regex::new(&pattern)
        .ok()
        .and_then(|re| re.captures(content))
        .map(|caps| caps[1].trim().to_string())
        .unwrap_or_default()
}

fn parse_section(content: &str, section: &str) -> Vec<String> {
    let header = format!("## {}", section);
    let mut in_section = false;
    let mut items = Vec::new();

    for line in content.lines() {
        if line.trim().starts_with(&header) {
            in_section = true;
            continue;
        }
        if in_section && line.starts_with("## ") {
            break;
        }
        if in_section {
            let trimmed = line.trim();
            if let Some(stripped) = trimmed.strip_prefix("- ") {
                items.push(stripped.to_string());
            } else if !trimmed.is_empty() && !trimmed.starts_with("<!--") {
                items.push(trimmed.to_string());
            }
        }
    }
    items
}

fn detect_client(id: &str) -> String {
    if id.starts_with("claude") {
        "Claude Code".to_string()
    } else if id.starts_with("gemini") {
        "Gemini CLI".to_string()
    } else if id.starts_with("codex") {
        "Codex CLI".to_string()
    } else {
        "Unknown".to_string()
    }
}

#[tauri::command]
pub fn get_sessions(barrack_path: String) -> Result<Vec<SessionInfo>, String> {
    let sessions_dir = PathBuf::from(&barrack_path).join("sessions");
    let mut sessions = Vec::new();

    let entries =
        fs::read_dir(&sessions_dir).map_err(|e| format!("sessions 디렉토리 읽기 실패: {}", e))?;

    for entry in entries.flatten() {
        let filename = entry.file_name().to_string_lossy().to_string();
        if !filename.ends_with(".md") || filename == ".active" {
            continue;
        }

        let id = filename.trim_end_matches(".md").to_string();
        let content = fs::read_to_string(entry.path()).unwrap_or_default();

        let client_field = parse_field(&content, "Client");
        let client = if client_field.is_empty() {
            detect_client(&id)
        } else {
            client_field
        };

        sessions.push(SessionInfo {
            id: id.clone(),
            client,
            started: parse_field(&content, "Started"),
            ended: parse_field(&content, "Ended"),
            status: parse_field(&content, "Status"),
            task: parse_field(&content, "Task"),
            continues: parse_field(&content, "Continues"),
        });
    }

    sessions.sort_by(|a, b| b.id.cmp(&a.id));
    Ok(sessions)
}

#[tauri::command]
pub fn get_session_detail(
    barrack_path: String,
    session_id: String,
) -> Result<SessionDetail, String> {
    let barrack = PathBuf::from(&barrack_path);
    let file_path = barrack.join("sessions").join(format!("{}.md", session_id));

    // Read once: the same bytes feed the seal hash and the parsed/raw content.
    let bytes = fs::read(&file_path).map_err(|e| format!("세션 파일 읽기 실패: {}", e))?;
    let seal_status = seal_status(&barrack, &session_id, &bytes).to_string();
    let content = String::from_utf8_lossy(&bytes).into_owned();

    let client_field = parse_field(&content, "Client");
    let client = if client_field.is_empty() {
        detect_client(&session_id)
    } else {
        client_field
    };

    let info = SessionInfo {
        id: session_id,
        client,
        started: parse_field(&content, "Started"),
        ended: parse_field(&content, "Ended"),
        status: parse_field(&content, "Status"),
        task: parse_field(&content, "Task"),
        continues: parse_field(&content, "Continues"),
    };

    Ok(SessionDetail {
        info,
        log: parse_section(&content, "Log"),
        decisions: parse_section(&content, "Decisions"),
        blockers: parse_section(&content, "Blockers"),
        wiki_extractions: parse_section(&content, "Wiki Extractions"),
        identity_suggestions: parse_section(&content, "Identity Suggestions"),
        raw_content: content,
        seal_status,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    const SID: &str = "claude-20261014-1000";
    const BODY: &str = "- **Status**: completed\n## Log\n- [10:00] work\n";

    fn barrack_with(body: &str, seal: Option<&str>) -> TempDir {
        let tmp = TempDir::new().unwrap();
        let sessions = tmp.path().join("sessions");
        fs::create_dir_all(sessions.join(".seals")).unwrap();
        fs::write(sessions.join(format!("{SID}.md")), body).unwrap();
        if let Some(seal) = seal {
            fs::write(sessions.join(".seals").join(format!("{SID}.sha256")), seal).unwrap();
        }
        tmp
    }

    fn seal_line(body: &str) -> String {
        format!("{}  sessions/{SID}.md\n", sha256_hex(body.as_bytes()))
    }

    fn status_of(tmp: &TempDir) -> String {
        get_session_detail(tmp.path().to_string_lossy().into_owned(), SID.to_string())
            .unwrap()
            .seal_status
    }

    #[test]
    fn sha256_hex_matches_known_vector() {
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn seal_status_intact_when_hash_matches() {
        let tmp = barrack_with(BODY, Some(&seal_line(BODY)));
        assert_eq!(status_of(&tmp), "intact");
    }

    #[test]
    fn seal_status_modified_after_change() {
        let tmp = barrack_with(&format!("{BODY}- [11:00] edited\n"), Some(&seal_line(BODY)));
        assert_eq!(status_of(&tmp), "modified");
    }

    #[test]
    fn seal_status_unsealed_without_seal_file() {
        let tmp = barrack_with(BODY, None);
        assert_eq!(status_of(&tmp), "unsealed");
    }

    #[test]
    fn seal_status_invalid_for_malformed_or_mismatched_seal() {
        let garbage = barrack_with(BODY, Some("garbage\n"));
        assert_eq!(status_of(&garbage), "invalid");
        let other_path = seal_line(BODY).replace(&format!("sessions/{SID}.md"), "sessions/other.md");
        let mismatched = barrack_with(BODY, Some(&other_path));
        assert_eq!(status_of(&mismatched), "invalid");
        let two_records = format!("{}{}", seal_line(BODY), seal_line(BODY));
        let multi = barrack_with(BODY, Some(&two_records));
        assert_eq!(status_of(&multi), "invalid");
    }

    #[test]
    fn session_detail_serializes_seal_status_key() {
        let tmp = barrack_with(BODY, Some(&seal_line(BODY)));
        let detail =
            get_session_detail(tmp.path().to_string_lossy().into_owned(), SID.to_string()).unwrap();
        let json = serde_json::to_value(&detail).unwrap();
        assert_eq!(json["seal_status"], "intact");
        assert_eq!(json["raw_content"], BODY);
    }
}
