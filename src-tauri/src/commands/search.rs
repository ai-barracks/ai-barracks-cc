use serde::Serialize;
use std::fs;
use std::path::PathBuf;

const SNIPPET_CHARS: usize = 120;

#[derive(Debug, Serialize)]
pub struct SearchResult {
    pub barrack: String,
    pub source: String, // "session", "wiki", "rules", "config"
    pub title: String,
    pub snippet: String,
    pub file_path: String,
}

fn search_in_file(path: &PathBuf, query_lower: &str) -> Vec<(String, String)> {
    let content = match fs::read_to_string(path) {
        Ok(c) => c,
        Err(_) => return Vec::new(),
    };

    let mut matches = Vec::new();
    for line in content.lines() {
        if line.to_lowercase().contains(query_lower) {
            let snippet = make_snippet(line);
            matches.push((snippet, path.to_string_lossy().to_string()));
            if matches.len() >= 3 {
                break;
            }
        }
    }
    matches
}

fn make_snippet(line: &str) -> String {
    let mut chars = line.chars();
    let snippet: String = chars.by_ref().take(SNIPPET_CHARS).collect();
    if chars.next().is_some() {
        format!("{}...", snippet)
    } else {
        line.to_string()
    }
}

#[tauri::command]
pub fn search_all(query: String) -> Result<Vec<SearchResult>, String> {
    if query.trim().len() < 2 {
        return Ok(Vec::new());
    }

    let query_lower = query.to_lowercase();
    let registry_path = dirs::home_dir()
        .unwrap_or_default()
        .join(".aib")
        .join("barracks.json");

    let content = fs::read_to_string(&registry_path)
        .map_err(|e| format!("barracks.json 읽기 실패: {}", e))?;

    let entries: Vec<serde_json::Value> =
        serde_json::from_str(&content).map_err(|e| format!("JSON 파싱 실패: {}", e))?;

    let mut results = Vec::new();

    for entry in &entries {
        let barrack_path = entry["path"].as_str().unwrap_or_default();
        let barrack_name = entry["name"].as_str().unwrap_or_default();
        let base = PathBuf::from(barrack_path);

        if !base.exists() {
            continue;
        }

        // Search sessions
        let sessions_dir = base.join("sessions");
        if let Ok(entries) = fs::read_dir(&sessions_dir) {
            for file in entries.flatten() {
                let fname = file.file_name().to_string_lossy().to_string();
                if !fname.ends_with(".md") || fname == ".active" {
                    continue;
                }
                let session_id = fname.trim_end_matches(".md");
                for (snippet, fpath) in search_in_file(&file.path(), &query_lower) {
                    results.push(SearchResult {
                        barrack: barrack_name.to_string(),
                        source: "session".to_string(),
                        title: session_id.to_string(),
                        snippet,
                        file_path: fpath,
                    });
                }
            }
        }

        // Search wiki topics
        let topics_dir = base.join("wiki").join("topics");
        if let Ok(entries) = fs::read_dir(&topics_dir) {
            for file in entries.flatten() {
                let fname = file.file_name().to_string_lossy().to_string();
                if !fname.ends_with(".md") {
                    continue;
                }
                let topic_name = fname.trim_end_matches(".md");
                for (snippet, fpath) in search_in_file(&file.path(), &query_lower) {
                    results.push(SearchResult {
                        barrack: barrack_name.to_string(),
                        source: "wiki".to_string(),
                        title: topic_name.to_string(),
                        snippet,
                        file_path: fpath,
                    });
                }
            }
        }

        // Search RULES.md
        let rules_path = base.join("RULES.md");
        for (snippet, fpath) in search_in_file(&rules_path, &query_lower) {
            results.push(SearchResult {
                barrack: barrack_name.to_string(),
                source: "rules".to_string(),
                title: "RULES.md".to_string(),
                snippet,
                file_path: fpath,
            });
        }

        // Search SOUL.md
        let soul_path = base.join("SOUL.md");
        for (snippet, fpath) in search_in_file(&soul_path, &query_lower) {
            results.push(SearchResult {
                barrack: barrack_name.to_string(),
                source: "config".to_string(),
                title: "SOUL.md".to_string(),
                snippet,
                file_path: fpath,
            });
        }

        // Search GROWTH.md
        let growth_path = base.join("GROWTH.md");
        for (snippet, fpath) in search_in_file(&growth_path, &query_lower) {
            results.push(SearchResult {
                barrack: barrack_name.to_string(),
                source: "config".to_string(),
                title: "GROWTH.md".to_string(),
                snippet,
                file_path: fpath,
            });
        }
    }

    // Limit results
    results.truncate(50);
    Ok(results)
}

#[cfg(test)]
mod tests {
    use super::{make_snippet, search_in_file, SNIPPET_CHARS};
    use std::fs;

    #[test]
    fn snippet_truncates_by_char_boundary() {
        let line = format!("{}needle", "가🙂".repeat(80));
        let snippet = make_snippet(&line);
        assert!(snippet.ends_with("..."));
        assert_eq!(
            snippet.trim_end_matches("...").chars().count(),
            SNIPPET_CHARS
        );
        assert!(snippet.is_char_boundary(snippet.len()));
    }

    #[test]
    fn search_long_unicode_line_does_not_panic() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("unicode.md");
        let line = format!("{}needle", "한글🙂".repeat(80));
        fs::write(&file, line).unwrap();

        let matches = search_in_file(&file, "needle");
        assert_eq!(matches.len(), 1);
        assert!(matches[0].0.ends_with("..."));
        assert_eq!(
            matches[0].0.trim_end_matches("...").chars().count(),
            SNIPPET_CHARS
        );
    }

    #[test]
    fn short_snippet_is_unchanged() {
        assert_eq!(make_snippet("short needle"), "short needle");
    }
}
