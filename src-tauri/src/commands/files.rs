use std::fs;
use std::path::PathBuf;
use serde::Serialize;

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
