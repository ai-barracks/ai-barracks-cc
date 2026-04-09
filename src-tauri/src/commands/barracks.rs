use serde::{Deserialize, Deserializer, Serialize};
use std::fs;
use std::path::PathBuf;

/// Deserialize a field that can be either a string (comma-separated) or an array of strings
fn string_or_vec<'de, D>(deserializer: D) -> Result<Vec<String>, D::Error>
where
    D: Deserializer<'de>,
{
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum StringOrVec {
        Str(String),
        Vec(Vec<String>),
    }

    match StringOrVec::deserialize(deserializer)? {
        StringOrVec::Str(s) => {
            if s.is_empty() {
                Ok(Vec::new())
            } else {
                Ok(s.split(',').map(|x| x.trim().to_string()).collect())
            }
        }
        StringOrVec::Vec(v) => Ok(v),
    }
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct BarrackEntry {
    pub path: String,
    pub name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default, deserialize_with = "string_or_vec")]
    pub expertise: Vec<String>,
    #[serde(default, deserialize_with = "string_or_vec")]
    pub topics: Vec<String>,
}

#[derive(Debug, Serialize, Clone)]
pub struct BarrackInfo {
    pub path: String,
    pub name: String,
    pub description: String,
    pub expertise: Vec<String>,
    pub topics: Vec<String>,
    pub aib_version: String,
    pub session_count: usize,
    pub active_sessions: usize,
    pub wiki_topic_count: usize,
    pub rules_count: RulesCount,
    pub soul_summary: SoulSummary,
}

#[derive(Debug, Serialize, Clone, Default)]
pub struct RulesCount {
    pub must_always: usize,
    pub must_never: usize,
    pub learned: usize,
}

#[derive(Debug, Serialize, Clone, Default)]
pub struct SoulSummary {
    pub name: String,
    pub expertise: Vec<String>,
    pub personality: Vec<String>,
}

fn registry_path() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_default()
        .join(".aib")
        .join("barracks.json")
}

fn count_sessions(barrack_path: &str) -> (usize, usize) {
    let sessions_dir = PathBuf::from(barrack_path).join("sessions");
    let mut total = 0;
    let mut active = 0;

    if let Ok(entries) = fs::read_dir(&sessions_dir) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if name.ends_with(".md") && name != ".active" {
                total += 1;
                if let Ok(content) = fs::read_to_string(entry.path()) {
                    if content.contains("**Status**: active") {
                        active += 1;
                    }
                }
            }
        }
    }
    (total, active)
}

fn count_wiki_topics(barrack_path: &str) -> usize {
    let topics_dir = PathBuf::from(barrack_path).join("wiki").join("topics");
    fs::read_dir(topics_dir)
        .map(|entries| {
            entries
                .flatten()
                .filter(|e| {
                    e.file_name()
                        .to_string_lossy()
                        .ends_with(".md")
                })
                .count()
        })
        .unwrap_or(0)
}

fn parse_rules_count(barrack_path: &str) -> RulesCount {
    let rules_path = PathBuf::from(barrack_path).join("RULES.md");
    let content = fs::read_to_string(rules_path).unwrap_or_default();

    let mut count = RulesCount::default();
    let mut current_section = "";

    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("## Must Always") {
            current_section = "must_always";
        } else if trimmed.starts_with("## Must Never") {
            current_section = "must_never";
        } else if trimmed.starts_with("## Learned") {
            current_section = "learned";
        } else if trimmed.starts_with("## ") {
            current_section = "";
        } else if trimmed.starts_with("- ") && !current_section.is_empty() {
            match current_section {
                "must_always" => count.must_always += 1,
                "must_never" => count.must_never += 1,
                "learned" => count.learned += 1,
                _ => {}
            }
        }
    }
    count
}

fn parse_soul_summary(barrack_path: &str) -> SoulSummary {
    let soul_path = PathBuf::from(barrack_path).join("SOUL.md");
    let content = fs::read_to_string(soul_path).unwrap_or_default();

    let mut summary = SoulSummary::default();
    let mut current_section = "";

    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("## Name") {
            current_section = "name";
        } else if trimmed.starts_with("## Expertise") {
            current_section = "expertise";
        } else if trimmed.starts_with("## Personality") {
            current_section = "personality";
        } else if trimmed.starts_with("## ") {
            current_section = "";
        } else {
            match current_section {
                "name" => {
                    if !trimmed.is_empty() && summary.name.is_empty() {
                        summary.name = trimmed.to_string();
                    }
                }
                "expertise" => {
                    if let Some(item) = trimmed.strip_prefix("- ") {
                        summary.expertise.push(item.to_string());
                    }
                }
                "personality" => {
                    if let Some(item) = trimmed.strip_prefix("- ") {
                        summary.personality.push(item.to_string());
                    }
                }
                _ => {}
            }
        }
    }
    summary
}

fn parse_aib_version(barrack_path: &str) -> String {
    let yaml_path = PathBuf::from(barrack_path).join("agent.yaml");
    let content = fs::read_to_string(yaml_path).unwrap_or_default();

    for line in content.lines() {
        if let Some(ver) = line.strip_prefix("aib_version:") {
            return ver.trim().to_string();
        }
    }
    "unknown".to_string()
}

#[tauri::command]
pub fn get_barracks() -> Result<Vec<BarrackInfo>, String> {
    let path = registry_path();
    let content = fs::read_to_string(&path)
        .map_err(|e| format!("barracks.json 읽기 실패: {}", e))?;

    let entries: Vec<BarrackEntry> =
        serde_json::from_str(&content).map_err(|e| format!("JSON 파싱 실패: {}", e))?;

    let barracks = entries
        .into_iter()
        .filter(|e| PathBuf::from(&e.path).exists())
        .map(|e| {
            let (session_count, active_sessions) = count_sessions(&e.path);
            let wiki_topic_count = count_wiki_topics(&e.path);
            let rules_count = parse_rules_count(&e.path);
            let soul_summary = parse_soul_summary(&e.path);
            let aib_version = parse_aib_version(&e.path);

            BarrackInfo {
                path: e.path,
                name: e.name,
                description: e.description,
                expertise: e.expertise,
                topics: e.topics,
                aib_version,
                session_count,
                active_sessions,
                wiki_topic_count,
                rules_count,
                soul_summary,
            }
        })
        .collect();

    Ok(barracks)
}

#[tauri::command]
pub fn get_cli_version() -> Result<String, String> {
    let output = std::process::Command::new(crate::aib_bin())
        .arg("version")
        .output()
        .map_err(|e| format!("aib 실행 실패: {}", e))?;

    let version_str = String::from_utf8_lossy(&output.stdout).trim().to_string();
    // "aib v0.8.2" → "0.8.2"
    Ok(version_str
        .strip_prefix("aib v")
        .unwrap_or(&version_str)
        .to_string())
}
