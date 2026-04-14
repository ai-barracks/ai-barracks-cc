use serde::Serialize;
use std::process::Command;

fn git(barrack_path: &str) -> Command {
    let mut cmd = Command::new("git");
    cmd.current_dir(barrack_path);
    cmd
}

fn run_git(barrack_path: &str, args: &[&str]) -> Result<String, String> {
    let output = git(barrack_path)
        .args(args)
        .output()
        .map_err(|e| format!("git 실행 실패: {}", e))?;

    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();

    if output.status.success() {
        Ok(stdout)
    } else {
        Err(stderr)
    }
}

#[derive(Debug, Serialize)]
pub struct GitStatus {
    pub is_repo: bool,
    pub git_root: String,
    pub is_sub_path: bool,
    pub branch: String,
    pub changed_files: usize,
    pub untracked_files: usize,
    pub staged_files: usize,
    pub ahead: usize,
    pub behind: usize,
    pub remote_url: String,
    pub last_commit: String,
    pub last_commit_time: String,
}

#[derive(Debug, Serialize)]
pub struct GitLogEntry {
    pub hash: String,
    pub message: String,
    pub author: String,
    pub date: String,
}

#[tauri::command]
pub fn get_git_status(barrack_path: String) -> Result<GitStatus, String> {
    let empty = GitStatus {
        is_repo: false,
        git_root: String::new(),
        is_sub_path: false,
        branch: String::new(),
        changed_files: 0,
        untracked_files: 0,
        staged_files: 0,
        ahead: 0,
        behind: 0,
        remote_url: String::new(),
        last_commit: String::new(),
        last_commit_time: String::new(),
    };

    // Check if it's a git repo
    if run_git(&barrack_path, &["rev-parse", "--git-dir"]).is_err() {
        return Ok(empty);
    }

    // Detect git root vs barrack path
    let git_root = run_git(&barrack_path, &["rev-parse", "--show-toplevel"]).unwrap_or_default();
    let normalized_barrack = std::path::Path::new(&barrack_path)
        .canonicalize()
        .unwrap_or_else(|_| std::path::PathBuf::from(&barrack_path));
    let normalized_root = std::path::Path::new(&git_root)
        .canonicalize()
        .unwrap_or_else(|_| std::path::PathBuf::from(&git_root));
    let is_sub_path = normalized_barrack != normalized_root;

    let branch = run_git(&barrack_path, &["branch", "--show-current"]).unwrap_or_default();

    // Count changed/untracked/staged — filter to barrack path if sub-path
    let status_output = if is_sub_path {
        run_git(&git_root, &["status", "--porcelain", "--", &barrack_path]).unwrap_or_default()
    } else {
        run_git(&barrack_path, &["status", "--porcelain"]).unwrap_or_default()
    };
    let mut changed = 0;
    let mut untracked = 0;
    let mut staged = 0;
    for line in status_output.lines() {
        if line.len() < 2 {
            continue;
        }
        let index = line.as_bytes()[0];
        let worktree = line.as_bytes()[1];
        if line.starts_with("??") {
            untracked += 1;
        } else {
            if index != b' ' && index != b'?' {
                staged += 1;
            }
            if worktree != b' ' && worktree != b'?' {
                changed += 1;
            }
        }
    }

    // Ahead/behind (repo-level, not path-filtered)
    let mut ahead = 0;
    let mut behind = 0;
    if let Ok(ab) = run_git(
        &barrack_path,
        &["rev-list", "--left-right", "--count", "HEAD...@{upstream}"],
    ) {
        let parts: Vec<&str> = ab.split_whitespace().collect();
        if parts.len() == 2 {
            ahead = parts[0].parse().unwrap_or(0);
            behind = parts[1].parse().unwrap_or(0);
        }
    }

    // Remote URL
    let remote_url = run_git(&barrack_path, &["remote", "get-url", "origin"]).unwrap_or_default();

    // Last commit (filtered to barrack path if sub-path)
    let (last_commit, last_commit_time) = if is_sub_path {
        (
            run_git(&git_root, &["log", "-1", "--format=%s", "--", &barrack_path]).unwrap_or_default(),
            run_git(&git_root, &["log", "-1", "--format=%ar", "--", &barrack_path]).unwrap_or_default(),
        )
    } else {
        (
            run_git(&barrack_path, &["log", "-1", "--format=%s"]).unwrap_or_default(),
            run_git(&barrack_path, &["log", "-1", "--format=%ar"]).unwrap_or_default(),
        )
    };

    Ok(GitStatus {
        is_repo: true,
        git_root: git_root.clone(),
        is_sub_path,
        branch,
        changed_files: changed,
        untracked_files: untracked,
        staged_files: staged,
        ahead,
        behind,
        remote_url,
        last_commit,
        last_commit_time,
    })
}

fn detect_git_root(barrack_path: &str) -> Option<(String, bool)> {
    let git_root = run_git(barrack_path, &["rev-parse", "--show-toplevel"]).ok()?;
    let normalized_barrack = std::path::Path::new(barrack_path)
        .canonicalize()
        .unwrap_or_else(|_| std::path::PathBuf::from(barrack_path));
    let normalized_root = std::path::Path::new(&git_root)
        .canonicalize()
        .unwrap_or_else(|_| std::path::PathBuf::from(&git_root));
    let is_sub = normalized_barrack != normalized_root;
    Some((git_root, is_sub))
}

#[tauri::command]
pub fn get_git_log(barrack_path: String, count: usize) -> Result<Vec<GitLogEntry>, String> {
    let n = format!("-{}", count.min(50));

    let output = match detect_git_root(&barrack_path) {
        Some((root, true)) => {
            // Sub-path: filter log to barrack directory
            run_git(&root, &["log", &n, "--format=%H|||%s|||%an|||%ar", "--", &barrack_path])?
        }
        _ => {
            run_git(&barrack_path, &["log", &n, "--format=%H|||%s|||%an|||%ar"])?
        }
    };

    let entries = output
        .lines()
        .filter_map(|line| {
            let parts: Vec<&str> = line.splitn(4, "|||").collect();
            if parts.len() == 4 {
                Some(GitLogEntry {
                    hash: parts[0][..7.min(parts[0].len())].to_string(),
                    message: parts[1].to_string(),
                    author: parts[2].to_string(),
                    date: parts[3].to_string(),
                })
            } else {
                None
            }
        })
        .collect();

    Ok(entries)
}

#[tauri::command]
pub fn git_commit(barrack_path: String, message: String) -> Result<String, String> {
    match detect_git_root(&barrack_path) {
        Some((root, true)) => {
            // Sub-path: stage only barrack files, commit from root
            run_git(&root, &["add", "--", &barrack_path])?;
            run_git(&root, &["commit", "-m", &message])
        }
        _ => {
            run_git(&barrack_path, &["add", "-A"])?;
            run_git(&barrack_path, &["commit", "-m", &message])
        }
    }
}

#[tauri::command]
pub fn git_push(barrack_path: String) -> Result<String, String> {
    match detect_git_root(&barrack_path) {
        Some((root, true)) => run_git(&root, &["push"]),
        _ => run_git(&barrack_path, &["push"]),
    }
}
