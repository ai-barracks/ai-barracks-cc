use std::process::Command;

fn aib() -> Command {
    Command::new(crate::aib_bin())
}

#[tauri::command]
pub fn sync_barrack(barrack_path: String, dry_run: bool) -> Result<String, String> {
    let mut cmd = aib();
    cmd.arg("sync");
    if dry_run {
        cmd.arg("--dry-run");
    }
    cmd.arg(&barrack_path);

    let output = cmd.output().map_err(|e| format!("aib sync 실행 실패: {}", e))?;

    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();

    if output.status.success() {
        Ok(format!("{}\n{}", stdout, stderr))
    } else {
        Err(format!("Sync 실패:\n{}\n{}", stdout, stderr))
    }
}

#[tauri::command]
pub fn sync_all_barracks(paths: Vec<String>, dry_run: bool) -> Result<Vec<SyncResult>, String> {
    let results: Vec<SyncResult> = paths
        .iter()
        .map(|path| {
            match sync_barrack(path.clone(), dry_run) {
                Ok(output) => SyncResult {
                    path: path.clone(),
                    success: true,
                    output,
                },
                Err(err) => SyncResult {
                    path: path.clone(),
                    success: false,
                    output: err,
                },
            }
        })
        .collect();

    Ok(results)
}

#[derive(serde::Serialize)]
pub struct SyncResult {
    pub path: String,
    pub success: bool,
    pub output: String,
}

#[tauri::command]
pub fn remove_barrack(path: String) -> Result<String, String> {
    let output = aib()
        .arg("barracks")
        .arg("remove")
        .arg(&path)
        .output()
        .map_err(|e| format!("aib barracks remove 실행 실패: {}", e))?;

    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();

    if output.status.success() {
        Ok(format!("{}\n{}", stdout, stderr))
    } else {
        Err(format!("배럭 제거 실패:\n{}\n{}", stdout, stderr))
    }
}

#[tauri::command]
pub fn create_barrack(path: String) -> Result<String, String> {
    let output = aib()
        .arg("init")
        .arg(&path)
        .output()
        .map_err(|e| format!("aib init 실행 실패: {}", e))?;

    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();

    if output.status.success() {
        Ok(format!("{}\n{}", stdout, stderr))
    } else {
        Err(format!("배럭 생성 실패:\n{}\n{}", stdout, stderr))
    }
}

fn aib_path() -> String {
    crate::aib_bin()
}

#[tauri::command]
pub fn refresh_barracks() -> Result<String, String> {
    let output = aib()
        .arg("barracks")
        .arg("refresh")
        .output()
        .map_err(|e| format!("aib barracks refresh 실행 실패: {}", e))?;

    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();

    if output.status.success() {
        Ok(format!("{}\n{}", stdout, stderr))
    } else {
        Err(format!("Refresh 실패:\n{}\n{}", stdout, stderr))
    }
}

#[derive(serde::Serialize)]
pub struct LaunchCommand {
    pub cwd: String,
    pub command: String,
}

#[tauri::command]
pub fn get_launch_command(
    barrack_path: String,
    client: String,
    skip_permissions: bool,
) -> Result<LaunchCommand, String> {
    let aib = aib_path();
    let skip_flag = if skip_permissions { " --skip-permissions" } else { "" };
    let command = format!("{} start {}{}", aib, client, skip_flag);
    Ok(LaunchCommand { cwd: barrack_path, command })
}

#[tauri::command]
pub fn get_continue_command(
    barrack_path: String,
    client: String,
    session_id: String,
    skip_permissions: bool,
) -> Result<LaunchCommand, String> {
    let aib = aib_path();
    let skip_flag = if skip_permissions { " --skip-permissions" } else { "" };
    let continue_prompt = format!(
        "이전 세션 {}의 작업을 이어서 진행해주세요. sessions/{}.md 파일을 읽고 작업을 계속하세요.",
        session_id, session_id
    );
    let command = format!("{} start {}{} '{}'", aib, client, skip_flag, continue_prompt);
    Ok(LaunchCommand { cwd: barrack_path, command })
}

#[tauri::command]
pub fn launch_session(barrack_path: String, client: String, skip_permissions: bool) -> Result<(), String> {
    let aib = aib_path();
    let skip_flag = if skip_permissions { " --skip-permissions" } else { "" };
    let script = format!(
        "tell application \"Terminal\"\n  activate\n  do script \"cd '{}' && {} start {}{}\"\nend tell",
        barrack_path, aib, client, skip_flag
    );

    Command::new("osascript")
        .arg("-e")
        .arg(&script)
        .spawn()
        .map_err(|e| format!("터미널 실행 실패: {}", e))?;

    Ok(())
}

#[tauri::command]
pub fn continue_session(barrack_path: String, client: String, session_id: String, skip_permissions: bool) -> Result<(), String> {
    let aib = aib_path();
    let skip_flag = if skip_permissions { " --skip-permissions" } else { "" };
    let continue_prompt = format!(
        "이전 세션 {}의 작업을 이어서 진행해주세요. sessions/{}.md 파일을 읽고 작업을 계속하세요.",
        session_id, session_id
    );
    let script = format!(
        "tell application \"Terminal\"\n  activate\n  do script \"cd '{}' && {} start {}{} '{}'\"\nend tell",
        barrack_path, aib, client, skip_flag, continue_prompt
    );

    Command::new("osascript")
        .arg("-e")
        .arg(&script)
        .spawn()
        .map_err(|e| format!("터미널 실행 실패: {}", e))?;

    Ok(())
}
