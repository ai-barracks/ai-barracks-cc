use regex::Regex;
use serde::Serialize;
use std::fs;
use std::path::PathBuf;

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
            if trimmed.starts_with("- ") {
                items.push(trimmed[2..].to_string());
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

    let entries = fs::read_dir(&sessions_dir)
        .map_err(|e| format!("sessions 디렉토리 읽기 실패: {}", e))?;

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
pub fn get_session_detail(barrack_path: String, session_id: String) -> Result<SessionDetail, String> {
    let file_path = PathBuf::from(&barrack_path)
        .join("sessions")
        .join(format!("{}.md", session_id));

    let content = fs::read_to_string(&file_path)
        .map_err(|e| format!("세션 파일 읽기 실패: {}", e))?;

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
    })
}
