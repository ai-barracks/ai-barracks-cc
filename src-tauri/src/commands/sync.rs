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

    let output = cmd
        .output()
        .map_err(|e| format!("aib sync 실행 실패: {}", e))?;

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
        .map(|path| match sync_barrack(path.clone(), dry_run) {
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
pub fn get_aib_path() -> String {
    aib_path()
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
    let command = build_start_command(&client, skip_permissions, None);
    Ok(LaunchCommand {
        cwd: barrack_path,
        command,
    })
}

#[tauri::command]
pub fn get_continue_command(
    barrack_path: String,
    client: String,
    session_id: String,
    skip_permissions: bool,
) -> Result<LaunchCommand, String> {
    let continue_prompt = format!(
        "이전 세션 {}의 작업을 이어서 진행해주세요. sessions/{}.md 파일을 읽고 작업을 계속하세요.",
        session_id, session_id
    );
    let command = build_start_command(&client, skip_permissions, Some(&continue_prompt));
    Ok(LaunchCommand {
        cwd: barrack_path,
        command,
    })
}

#[tauri::command]
pub fn launch_session(
    barrack_path: String,
    client: String,
    skip_permissions: bool,
) -> Result<(), String> {
    let shell_script = format!(
        "cd {} && {}",
        shell_quote(&barrack_path),
        build_start_command(&client, skip_permissions, None)
    );
    let script = format!(
        "tell application \"Terminal\"\n  activate\n  do script \"{}\"\nend tell",
        apple_script_string(&shell_script)
    );

    Command::new("osascript")
        .arg("-e")
        .arg(&script)
        .spawn()
        .map_err(|e| format!("터미널 실행 실패: {}", e))?;

    Ok(())
}

#[tauri::command]
pub fn continue_session(
    barrack_path: String,
    client: String,
    session_id: String,
    skip_permissions: bool,
) -> Result<(), String> {
    let continue_prompt = format!(
        "이전 세션 {}의 작업을 이어서 진행해주세요. sessions/{}.md 파일을 읽고 작업을 계속하세요.",
        session_id, session_id
    );
    let shell_script = format!(
        "cd {} && {}",
        shell_quote(&barrack_path),
        build_start_command(&client, skip_permissions, Some(&continue_prompt))
    );
    let script = format!(
        "tell application \"Terminal\"\n  activate\n  do script \"{}\"\nend tell",
        apple_script_string(&shell_script)
    );

    Command::new("osascript")
        .arg("-e")
        .arg(&script)
        .spawn()
        .map_err(|e| format!("터미널 실행 실패: {}", e))?;

    Ok(())
}

fn build_start_command(client: &str, skip_permissions: bool, prompt: Option<&str>) -> String {
    let mut args = vec![aib_path(), "start".to_string(), client.to_string()];
    if skip_permissions {
        args.push("--skip-permissions".to_string());
    }
    if let Some(prompt) = prompt {
        args.push(prompt.to_string());
    }
    shell_join(&args)
}

fn shell_join(args: &[String]) -> String {
    args.iter()
        .map(|arg| shell_quote(arg))
        .collect::<Vec<_>>()
        .join(" ")
}

fn shell_quote(value: &str) -> String {
    if value.is_empty() {
        return "''".to_string();
    }
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn apple_script_string(value: &str) -> String {
    value
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\r', "\\r")
        .replace('\n', "\\n")
}

#[cfg(test)]
mod tests {
    use super::{apple_script_string, shell_join, shell_quote};

    #[test]
    fn shell_quote_handles_empty_and_single_quotes() {
        assert_eq!(shell_quote(""), "''");
        assert_eq!(shell_quote("/tmp/has space"), "'/tmp/has space'");
        assert_eq!(shell_quote("/tmp/o'clock"), "'/tmp/o'\\''clock'");
    }

    #[test]
    fn shell_join_quotes_every_argument() {
        let args = vec![
            "/usr/local/bin/aib".to_string(),
            "start".to_string(),
            "claude".to_string(),
            "이전 세션 a'b".to_string(),
        ];
        assert_eq!(
            shell_join(&args),
            "'/usr/local/bin/aib' 'start' 'claude' '이전 세션 a'\\''b'"
        );
    }

    #[test]
    fn apple_script_string_escapes_script_delimiters() {
        assert_eq!(
            apple_script_string("cd '/tmp/a' && echo \"x\"\\tail\nnext"),
            "cd '/tmp/a' && echo \\\"x\\\"\\\\tail\\nnext"
        );
    }
}
