use std::fs;
use std::path::PathBuf;
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

    let files = filenames
        .iter()
        .map(|name| {
            let file_path = base.join(name);
            let exists = file_path.exists();
            let content = if exists {
                fs::read_to_string(&file_path).unwrap_or_default()
            } else {
                String::new()
            };

            let (ownership, description) = classify_ownership(name);

            FileInfo {
                name: name.to_string(),
                path: file_path.to_string_lossy().to_string(),
                content,
                ownership: ownership.to_string(),
                description: description.to_string(),
                exists,
            }
        })
        .collect();

    Ok(files)
}

#[tauri::command]
pub fn read_file(file_path: String) -> Result<String, String> {
    fs::read_to_string(&file_path).map_err(|e| format!("파일 읽기 실패: {}", e))
}

#[tauri::command]
pub fn write_file(file_path: String, content: String) -> Result<(), String> {
    fs::write(&file_path, &content).map_err(|e| format!("파일 쓰기 실패: {}", e))
}

#[derive(Debug, Serialize, Deserialize)]
pub struct RulesData {
    pub must_always: Vec<String>,
    pub must_never: Vec<String>,
    pub learned: Vec<String>,
}

#[tauri::command]
pub fn get_rules(barrack_path: String) -> Result<RulesData, String> {
    let path = PathBuf::from(&barrack_path).join("RULES.md");
    let content = fs::read_to_string(&path).unwrap_or_default();

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
    let path = PathBuf::from(&barrack_path).join("RULES.md");

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

    fs::write(&path, &content).map_err(|e| format!("RULES.md 저장 실패: {}", e))
}
