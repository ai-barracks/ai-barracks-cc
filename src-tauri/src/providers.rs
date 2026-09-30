//! Read-only CLI metadata. Never starts a thread or sends a model turn.
use serde::Serialize;
use serde_json::{json, Value};
use std::{
    io::{BufRead, BufReader, Write},
    path::Path,
    process::{Child, Stdio},
    sync::mpsc,
    thread,
    time::{Duration, Instant},
};

#[derive(Serialize, Debug)]
pub struct ModelInfo {
    pub model: String,
    pub name: String,
    pub efforts: Vec<String>,
    pub is_default: bool,
}
#[derive(Serialize)]
pub struct ProviderInfo {
    pub client: String,
    pub models: Vec<ModelInfo>,
    pub source: String,
}
struct Server(Child);
impl Drop for Server {
    fn drop(&mut self) {
        #[cfg(unix)]
        unsafe {
            libc::kill(-(self.0.id() as i32), libc::SIGKILL);
        }
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
fn parse_models(value: &Value) -> Result<Vec<ModelInfo>, String> {
    let data = value["data"]
        .as_array()
        .ok_or("model/list schema not supported")?;
    if data.len() > 100 {
        return Err("Model page too large".into());
    }
    let mut models = Vec::new();
    for item in data {
        if item["hidden"] == true {
            continue;
        }
        let model = item["model"]
            .as_str()
            .filter(|s| !s.is_empty() && s.len() <= 200 && !s.chars().any(char::is_control))
            .ok_or("Invalid model identifier")?;
        let efforts = item["supportedReasoningEfforts"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|v| v["reasoningEffort"].as_str())
                    .filter(|s| ["none", "minimal", "low", "medium", "high", "xhigh"].contains(s))
                    .map(String::from)
                    .collect()
            })
            .unwrap_or_default();
        models.push(ModelInfo {
            model: model.into(),
            name: item["displayName"]
                .as_str()
                .unwrap_or(model)
                .chars()
                .take(200)
                .collect(),
            efforts,
            is_default: item["isDefault"] == true,
        });
    }
    Ok(models)
}
fn codex_models(binary: &Path) -> Result<Vec<ModelInfo>, String> {
    let dir = tempfile::tempdir().map_err(|_| "Cannot isolate metadata probe")?;
    let mut command = crate::activation::sanitized_command(binary, dir.path());
    command.args([
        "app-server",
        "--stdio",
        "--disable",
        "hooks",
        "--disable",
        "plugins",
        "--disable",
        "apps",
        "--disable",
        "memories",
        "-c",
        "analytics.enabled=false",
    ]);
    command.stdin(Stdio::piped()).stderr(Stdio::null());
    let mut server = Server(
        command
            .spawn()
            .map_err(|_| "Codex app-server could not start")?,
    );
    let mut input = server.0.stdin.take().ok_or("No app-server input")?;
    let output = server.0.stdout.take().ok_or("No app-server output")?;
    let (send, receive) = mpsc::sync_channel(32);
    thread::spawn(move || {
        let mut reader = BufReader::new(output);
        // Bounded protocol bytes and messages; an incompatible CLI fails closed.
        let mut total = 0;
        loop {
            let mut line = Vec::new();
            let result = std::io::Read::take(&mut reader, 65537).read_until(b'\n', &mut line);
            match result {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    total += n;
                    if n > 65536 || total > 512 * 1024 {
                        break;
                    }
                    if send.send(line).is_err() {
                        break;
                    }
                }
            }
        }
    });
    let deadline = Instant::now() + Duration::from_secs(12);
    {
    let mut exchange = |id: u32, method: &str, params: Value| -> Result<Value, String> {
        writeln!(
            input,
            "{}",
            json!({"id":id,"method":method,"params":params})
        )
        .map_err(|_| "Cannot send metadata request")?;
        input.flush().map_err(|_| "Cannot flush metadata request")?;
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            let bytes = receive
                .recv_timeout(remaining)
                .map_err(|_| "Codex metadata probe timed out or closed")?;
            let value: Value =
                serde_json::from_slice(&bytes).map_err(|_| "Invalid app-server protocol")?;
            if value["id"] == id {
                if value.get("error").is_some() {
                    return Err(
                        "Codex metadata request refused; use runtime default or custom model"
                            .into(),
                    );
                }
                return value
                    .get("result")
                    .cloned()
                    .ok_or("Missing metadata result".into());
            }
        }
    };
    exchange(
        1,
        "initialize",
        json!({"clientInfo":{"name":"ai-barracks-cc","version":env!("CARGO_PKG_VERSION")},"capabilities":{"experimentalApi":false}}),
    )?;
    // Notification MUST follow successful initialization, before model/list.
    // The initialization scope releases the mutable stdin borrow.
    }
    writeln!(input, "{}", json!({"method":"initialized"}))
        .map_err(|_| "Cannot initialize metadata client")?;
    input
        .flush()
        .map_err(|_| "Cannot initialize metadata client")?;
    let mut cursor: Option<String> = None;
    let mut all = Vec::new();
    for id in 2..=5 {
        writeln!(input, "{}", json!({"id":id,"method":"model/list","params":{"limit":50,"includeHidden":false,"cursor":cursor}})).map_err(|_| "Cannot request models")?;
        input.flush().map_err(|_| "Cannot request models")?;
        let result = loop {
            let bytes = receive
                .recv_timeout(deadline.saturating_duration_since(Instant::now()))
                .map_err(|_| "Codex metadata probe timed out or closed")?;
            let value: Value =
                serde_json::from_slice(&bytes).map_err(|_| "Invalid app-server protocol")?;
            if value["id"] == id {
                if value.get("error").is_some() {
                    return Err(
                        "model/list unavailable; use runtime default or custom model".into(),
                    );
                }
                break value["result"].clone();
            }
        };
        all.extend(parse_models(&result)?);
        let next = result["nextCursor"].as_str().map(String::from);
        if next.is_none() {
            break;
        }
        if next == cursor {
            return Err("Repeated model pagination cursor".into());
        }
        cursor = next;
        if id == 5 {
            return Err("Model list exceeds bounded pagination".into());
        }
    }
    let mut seen = std::collections::HashSet::new();
    all.retain(|m| seen.insert(m.model.clone()));
    if all.is_empty() {
        return Err("No models advertised by this CLI/account".into());
    }
    Ok(all)
}
#[tauri::command]
pub async fn get_provider_models(client: String) -> Result<ProviderInfo, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let (models, source) = match client.as_str() {
            "claude" => (
                vec!["sonnet", "opus", "haiku"]
                    .into_iter()
                    .map(|model| ModelInfo {
                        model: model.into(),
                        name: model.into(),
                        efforts: Vec::new(),
                        is_default: false,
                    })
                    .collect(),
                "Documented Claude aliases, not an account availability guarantee",
            ),
            "codex" => {
                let binary =
                    crate::activation::find_binary("codex").ok_or("Codex CLI not found")?;
                (
                    codex_models(&binary)?,
                    "Installed Codex app-server model/list (no model turn)",
                )
            }
            _ => return Err("Unsupported provider".into()),
        };
        Ok(ProviderInfo {
            client,
            models,
            source: source.into(),
        })
    })
    .await
    .map_err(|_| "Metadata worker failed")?
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    #[ignore = "explicit read-only installed CLI metadata check; never sends a turn"]
    fn installed_cli_metadata_smoke() {
        let binary = std::env::var_os("AIB_METADATA_CLI").expect("Set AIB_METADATA_CLI explicitly");
        let models = codex_models(Path::new(&binary)).unwrap();
        assert!(!models.is_empty());
        eprintln!("Advertised models: {} (no thread/turn requests)", models.len());
    }
    #[test]
    fn validates_runtime_models_not_static_ids() {
        let value = json!({"data":[{"model":"future-model","displayName":"Future","isDefault":true,"supportedReasoningEfforts":[{"reasoningEffort":"high"},{"reasoningEffort":"unknown"}]},{"model":"hidden","hidden":true}]});
        let models = parse_models(&value).unwrap();
        assert_eq!(models.len(), 1);
        assert_eq!(models[0].efforts, vec!["high"]);
        assert!(models[0].is_default);
        assert!(parse_models(&json!({"data":[{"model":"\n"}]})).is_err());
    }
    #[cfg(unix)]
    #[test]
    fn handshake_pagination_and_no_model_requests() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let binary = dir.path().join("codex");
        std::fs::write(&binary, r##"#!/bin/sh
read init
echo "$init" | grep -q '"method":"initialize"' || exit 1
echo '{"id":1,"result":{}}'
read initialized
echo "$initialized" | grep -q '"method":"initialized"' || exit 2
read models
echo "$models" | grep -q '"method":"model/list"' || exit 3
echo '{"id":2,"result":{"data":[{"model":"future","supportedReasoningEfforts":[]}],"nextCursor":"next"}}'
read models
echo "$models" | grep -q '"cursor":"next"' || exit 4
echo '{"id":3,"result":{"data":[{"model":"other"}],"nextCursor":null}}'
sleep 30
"##).unwrap();
        std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o700)).unwrap();
        let models = codex_models(&binary).unwrap();
        assert_eq!(models.len(), 2);
    }
}
