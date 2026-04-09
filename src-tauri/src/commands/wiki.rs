use serde::Serialize;
use std::fs;
use std::path::PathBuf;

#[derive(Debug, Serialize, Clone)]
pub struct WikiTopic {
    pub name: String,
    pub file: String,
    pub updated: String,
    pub summary: String,
}

#[derive(Debug, Serialize)]
pub struct WikiIndex {
    pub topics: Vec<WikiTopic>,
    pub recent_changes: Vec<String>,
}

#[tauri::command]
pub fn get_wiki_index(barrack_path: String) -> Result<WikiIndex, String> {
    let base = PathBuf::from(&barrack_path).join("wiki");
    let index_path = base.join("Index.md");
    let log_path = base.join("Log.md");

    let mut topics = Vec::new();

    // Parse Index.md table
    if let Ok(content) = fs::read_to_string(&index_path) {
        let mut in_table = false;
        for line in content.lines() {
            let trimmed = line.trim();
            // Detect table header
            if trimmed.starts_with("| Topic") {
                in_table = true;
                continue;
            }
            // Skip separator rows like |-------|------|---------|---------|
            if trimmed.contains("---") && trimmed.starts_with('|') {
                continue;
            }
            // Stop at next section
            if in_table && (trimmed.starts_with('#') || (!trimmed.starts_with('|') && !trimmed.is_empty())) {
                in_table = false;
                continue;
            }
            if in_table && trimmed.starts_with('|') {
                let cols: Vec<&str> = trimmed.split('|').collect();
                if cols.len() >= 5 {
                    let name = cols[1].trim().to_string();
                    let file_raw = cols[2].trim().to_string();
                    // Extract filename from markdown link: [file.md](topics/file.md)
                    let file = file_raw
                        .split('(')
                        .nth(1)
                        .and_then(|s| s.strip_suffix(')'))
                        .unwrap_or(&file_raw)
                        .to_string();
                    let updated = cols[3].trim().to_string();
                    let summary = cols[4].trim().to_string();

                    if !name.is_empty() && !name.contains("---") {
                        topics.push(WikiTopic {
                            name,
                            file,
                            updated,
                            summary,
                        });
                    }
                }
            }
        }
    }

    // Parse Log.md (last 20 entries)
    let recent_changes = if let Ok(content) = fs::read_to_string(&log_path) {
        content
            .lines()
            .filter(|l| l.trim().starts_with("- "))
            .take(20)
            .map(|l| l.trim().strip_prefix("- ").unwrap_or(l).to_string())
            .collect()
    } else {
        Vec::new()
    };

    Ok(WikiIndex {
        topics,
        recent_changes,
    })
}

#[tauri::command]
pub fn get_wiki_topic(barrack_path: String, topic_file: String) -> Result<String, String> {
    let file_path = PathBuf::from(&barrack_path).join("wiki").join(&topic_file);
    fs::read_to_string(&file_path).map_err(|e| format!("위키 토픽 읽기 실패: {}", e))
}
