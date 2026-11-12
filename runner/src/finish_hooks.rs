use crate::rpc::Result;
use fs2::FileExt;
use serde_json::{Value, json};
use std::{
    io::Write,
    path::{Path, PathBuf},
};
use toml_edit::{Array, DocumentMut, value};

const MARKER: &str = "--completion-hook";
struct ConnectionLock(std::fs::File);
impl Drop for ConnectionLock {
    fn drop(&mut self) {
        let _ = FileExt::unlock(&self.0);
    }
}
fn quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\\''"))
}
fn read(path: &Path) -> Result<Option<Vec<u8>>> {
    if !path.exists() {
        return Ok(None);
    }
    let metadata =
        std::fs::symlink_metadata(path).map_err(|_| "Could not read the CLI configuration.")?;
    if metadata.file_type().is_symlink() || metadata.len() > 2 * 1024 * 1024 {
        return Err("The CLI configuration is a link or is too large. It was left unchanged; connect manually instead.".into());
    }
    Ok(Some(
        std::fs::read(path).map_err(|_| "Could not read the CLI configuration.")?,
    ))
}
fn private_write(path: &Path, data: &[u8]) -> Result<()> {
    let parent = path.parent().ok_or("Invalid configuration location.")?;
    std::fs::create_dir_all(parent).map_err(|_| "Could not create the configuration directory.")?;
    let temporary = parent.join(format!(".reprise-{}.tmp", uuid::Uuid::new_v4()));
    let mut options = std::fs::OpenOptions::new();
    options.create_new(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options
        .open(&temporary)
        .map_err(|_| "Could not write the CLI configuration.")?;
    file.write_all(data)
        .map_err(|_| "Could not write the CLI configuration.")?;
    drop(file);
    std::fs::rename(temporary, path).map_err(|_| "Could not update the CLI configuration.".into())
}
fn backup(path: &Path, base: &Path) -> Result<()> {
    if let Some(bytes) = read(path)? {
        let folder = base.join("native-connections/backups");
        private_write(
            &folder.join(format!(
                "{}-{}",
                uuid::Uuid::new_v4(),
                path.file_name().unwrap_or_default().to_string_lossy()
            )),
            &bytes,
        )?;
    }
    Ok(())
}
fn owned(command: &Value, base: &Path) -> bool {
    command["command"]
        .as_str()
        .is_some_and(|c| c.contains(MARKER) && c.contains(&quote(&base.to_string_lossy())))
}
fn update_hooks(
    mut document: Value,
    provider: &str,
    host: &Path,
    base: &Path,
    install: bool,
) -> Result<Value> {
    let root = document
        .as_object_mut()
        .ok_or("Hook configuration must be a JSON object. The original was preserved.")?;
    if !root.contains_key("hooks") {
        root.insert("hooks".into(), json!({}));
    }
    let hooks = root
        .get_mut("hooks")
        .and_then(Value::as_object_mut)
        .ok_or("Invalid hooks object. The original was preserved.")?;
    // Remove only our own command handlers, including duplicates from older setups.
    for groups in hooks.values_mut() {
        let groups = groups
            .as_array_mut()
            .ok_or("Invalid hook groups. The original was preserved.")?;
        for group in groups.iter_mut() {
            let commands = group["hooks"]
                .as_array_mut()
                .ok_or("Invalid hook handlers. The original was preserved.")?;
            commands.retain(|h| !owned(h, base));
        }
        groups.retain(|g| g["hooks"].as_array().is_none_or(|a| !a.is_empty()));
    }
    hooks.retain(|_, groups| groups.as_array().is_none_or(|a| !a.is_empty()));
    if !install {
        return Ok(document);
    }
    let command = [
        host.to_string_lossy().into_owned(),
        MARKER.into(),
        provider.into(),
        "--base".into(),
        base.to_string_lossy().into_owned(),
    ]
    .iter()
    .map(|x| quote(x))
    .collect::<Vec<_>>()
    .join(" ");
    let events = match provider {
        "codex" => vec![
            "UserPromptSubmit",
            "PreToolUse",
            "PreModelRequest",
            "PostToolUse",
            "PermissionRequest",
            "Interrupt",
            "SessionEnd",
            "SubagentStart",
            "SubagentStop",
        ],
        "claude" => vec![
            "UserPromptSubmit",
            "PreToolUse",
            "PostToolUse",
            "PermissionRequest",
            "Stop",
            "StopFailure",
            "SessionEnd",
            "SubagentStart",
            "SubagentStop",
            "Notification",
        ],
        "grok" => vec![
            "UserPromptSubmit",
            "PreToolUse",
            "PostToolUse",
            "Stop",
            "StopFailure",
            "StopCancelled",
            "SessionEnd",
            "SubagentStart",
            "SubagentStop",
            "Notification",
        ],
        _ => return Err("Unknown assistant.".into()),
    };
    for event in events {
        let mut group = json!({"hooks":[{"type":"command","command":command,"timeout":3}]});
        if event == "Notification" {
            group["matcher"] = json!(
                "idle_prompt|permission_prompt|agent_needs_input|elicitation_dialog|elicitation_url_dialog"
            );
        }
        hooks
            .entry(event)
            .or_insert(json!([]))
            .as_array_mut()
            .ok_or("Invalid hook groups.")?
            .push(group);
    }
    Ok(document)
}

fn notify_array(document: &DocumentMut) -> Result<Option<Vec<String>>> {
    let Some(item) = document.get("notify") else {
        return Ok(None);
    };
    let array = item.as_array().ok_or(
        "Codex notify is not a command array. It was preserved; configure the connection manually.",
    )?;
    let values = array
        .iter()
        .map(|v| v.as_str().map(String::from))
        .collect::<Option<Vec<_>>>()
        .ok_or("Codex notify contains unsupported values. It was preserved.")?;
    Ok(Some(values))
}
fn notify_item(values: &[String]) -> toml_edit::Item {
    let mut array = Array::new();
    for v in values {
        array.push(v.as_str());
    }
    value(array)
}

pub fn configure(
    provider: &str,
    root: &Path,
    host: &Path,
    base: &Path,
    install: bool,
) -> Result<String> {
    if !["codex", "claude", "grok"].contains(&provider)
        || !root.is_absolute()
        || !base.is_absolute()
        || !host.is_absolute()
    {
        return Err("Invalid completion connection request.".into());
    }
    let connection = base.join("native-connections");
    std::fs::create_dir_all(&connection)
        .map_err(|_| "Could not create the completion connection.")?;
    let lock = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(connection.join("install.lock"))
        .map_err(|_| "Could not reserve the completion connection.")?;
    lock.try_lock_exclusive()
        .map_err(|_| "Another completion connection is being updated. Try again shortly.")?;
    let _lock = ConnectionLock(lock);
    let hooks_file = match provider {
        "claude" => root.join("settings.json"),
        "grok" => root.join("hooks/reprise-finish.json"),
        _ => root.join("hooks.json"),
    };
    let bytes = read(&hooks_file)?.unwrap_or_else(|| b"{}".to_vec());
    let original: Value = serde_json::from_slice(&bytes)
        .map_err(|_| "The CLI hook configuration could not be parsed. It was left unchanged.")?;
    if provider == "grok"
        && hooks_file.exists()
        && original["description"] != "Reprise completion detection"
    {
        return Err("A different file already uses reprise-finish.json. It was preserved; rename it before connecting.".into());
    }
    let mut updated = update_hooks(original, provider, host, base, install)?;
    if provider == "grok" {
        updated["description"] = json!("Reprise completion detection");
    }
    let updated = serde_json::to_vec_pretty(&updated)
        .map_err(|_| "Could not encode the hook configuration.")?;
    if provider == "codex" {
        let config = root.join("config.toml");
        let text = String::from_utf8(read(&config)?.unwrap_or_default())
            .map_err(|_| "Codex configuration is not UTF-8. It was preserved.")?;
        let mut doc = text
            .parse::<DocumentMut>()
            .map_err(|_| "Codex configuration could not be parsed. It was preserved.")?;
        let current = notify_array(&doc)?;
        let wrapper = vec![
            host.to_string_lossy().into_owned(),
            "--completion-notify".into(),
            "codex".into(),
            "--base".into(),
            base.to_string_lossy().into_owned(),
        ];
        let state_file = connection.join("codex-notify.json");
        let old=read(&state_file)?.map(|bytes|serde_json::from_slice::<Value>(&bytes).map_err(|_|"The original Codex notifier backup could not be read. Nothing was changed.")).transpose()?;
        let already_owned = old.as_ref().is_some_and(|v| v["wrapper"] == json!(current));
        if install {
            if current
                .as_ref()
                .is_some_and(|a| a.iter().any(|x| x == "--completion-notify"))
                && !already_owned
            {
                return Err(
                    "The Codex completion notifier has no matching backup. It was left unchanged."
                        .into(),
                );
            }
            let original = if already_owned {
                old.as_ref().unwrap()["original"].clone()
            } else {
                json!(current)
            };
            backup(&config, base)?;
            backup(&hooks_file, base)?;
            private_write(
                &state_file,
                &serde_json::to_vec_pretty(&json!({"original":original,"wrapper":wrapper}))
                    .map_err(|_| "Could not save the original notifier.")?,
            )?;
            doc["notify"] = notify_item(&wrapper);
            private_write(&hooks_file, &updated)?;
            if let Err(error) = private_write(&config, doc.to_string().as_bytes()) {
                let _ = private_write(&hooks_file, &bytes);
                return Err(error);
            }
        } else {
            backup(&hooks_file, base)?;
            if already_owned {
                let old = old.as_ref().unwrap();
                if old["original"].is_null() {
                    doc.remove("notify");
                } else {
                    let original =
                        serde_json::from_value::<Vec<String>>(old["original"].clone())
                            .map_err(|_| "Invalid original notifier backup. It was preserved.")?;
                    doc["notify"] = notify_item(&original);
                }
                backup(&config, base)?;
                private_write(&config, doc.to_string().as_bytes())?;
            }
            private_write(&hooks_file, &updated)?;
            if already_owned {
                let _ = std::fs::remove_file(state_file);
            }
        }
    } else {
        backup(&hooks_file, base)?;
        if provider == "grok" && !install {
            // Preserve any foreign handlers someone added to our file after setup.
            let document: Value = serde_json::from_slice(&updated).map_err(|_| "Invalid hooks.")?;
            if document["hooks"].as_object().is_some_and(|h| h.is_empty()) {
                if hooks_file.exists() {
                    std::fs::remove_file(&hooks_file)
                        .map_err(|_| "Could not remove the completion hooks.")?;
                }
            } else {
                private_write(&hooks_file, &updated)?;
            }
        } else {
            private_write(&hooks_file, &updated)?;
        }
    }
    Ok(if install {
        format!(
            "Connected. {}",
            if provider == "codex" {
                "Restart existing sessions and review Reprise hooks in /hooks. Your previous notify command is forwarded."
            } else {
                "Reload hooks or restart existing sessions. Native replies use the idle confirmation after about a minute."
            }
        )
    } else {
        "Disconnected. Other hooks and settings were preserved.".into()
    })
}

pub fn command(args: &[String]) -> Result<String> {
    if !cfg!(target_os = "macos") {
        return Err("Completion actions are currently a Mac feature.".into());
    }
    let mode = args.get(1).ok_or("Missing connection operation.")?;
    let provider = args.get(2).ok_or("Missing assistant.")?;
    if !["install", "remove"].contains(&mode.as_str()) {
        return Err("Invalid connection operation.".into());
    }
    let option = |name: &str| {
        args.iter()
            .position(|s| s == name)
            .and_then(|i| args.get(i + 1))
            .map(PathBuf::from)
            .ok_or(format!("Missing {name}."))
    };
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or("Home folder is unavailable.")?;
    let root = match provider.as_str() {
        "codex" => std::env::var_os("CODEX_HOME")
            .map(PathBuf::from)
            .unwrap_or(home.join(".codex")),
        "claude" => std::env::var_os("CLAUDE_CONFIG_DIR")
            .map(PathBuf::from)
            .unwrap_or(home.join(".claude")),
        "grok" => std::env::var_os("GROK_HOME")
            .map(PathBuf::from)
            .unwrap_or(home.join(".grok")),
        _ => return Err("Unknown assistant.".into()),
    };
    configure(
        provider,
        &root,
        &option("--host")?,
        &option("--base")?,
        mode == "install",
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Folder(PathBuf);
    impl Drop for Folder {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    fn folder() -> Folder {
        let path = std::env::temp_dir().join(uuid::Uuid::new_v4().to_string());
        std::fs::create_dir_all(&path).unwrap();
        Folder(path)
    }
    #[test]
    fn codex_notifier_is_chained_idempotently_and_restored_without_losing_edits() {
        let f = folder();
        let root = f.0.join("codex");
        std::fs::create_dir_all(&root).unwrap();
        let base = f.0.join("data");
        let host = f.0.join("Reprise");
        std::fs::write(root.join("config.toml"),"# Keep this comment\nnotify = ['python3', '/notify.py']\nmodel = 'my-model'\n[other]\nenabled = true\n").unwrap();
        configure("codex", &root, &host, &base, true).unwrap();
        configure("codex", &root, &host, &base, true).unwrap();
        let backup: Value = serde_json::from_slice(
            &std::fs::read(base.join("native-connections/codex-notify.json")).unwrap(),
        )
        .unwrap();
        assert_eq!(backup["original"], json!(["python3", "/notify.py"]));
        let config = std::fs::read_to_string(root.join("config.toml")).unwrap();
        assert!(config.contains("# Keep this comment"));
        assert!(config.contains("my-model"));
        let edited = config.replace("my-model", "user-edited");
        std::fs::write(root.join("config.toml"), edited).unwrap();
        configure("codex", &root, &host, &base, false).unwrap();
        let restored = std::fs::read_to_string(root.join("config.toml"))
            .unwrap()
            .parse::<DocumentMut>()
            .unwrap();
        assert_eq!(
            notify_array(&restored).unwrap().unwrap(),
            vec!["python3", "/notify.py"]
        );
        assert_eq!(restored["model"].as_str(), Some("user-edited"));
    }
    #[test]
    fn claude_connections_preserve_foreign_hooks_and_permissions() {
        let f = folder();
        let root = f.0.join("claude");
        std::fs::create_dir_all(&root).unwrap();
        let base = f.0.join("data");
        let host = f.0.join("Reprise");
        let document = json!({"permissions":{"deny":["Bash(rm:*)"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"my-stop-check"}]}]}});
        std::fs::write(root.join("settings.json"), document.to_string()).unwrap();
        configure("claude", &root, &host, &base, true).unwrap();
        configure("claude", &root, &host, &base, true).unwrap();
        let connected: Value =
            serde_json::from_slice(&std::fs::read(root.join("settings.json")).unwrap()).unwrap();
        assert_eq!(connected["hooks"]["Stop"].as_array().unwrap().len(), 2);
        configure("claude", &root, &host, &base, false).unwrap();
        let restored: Value =
            serde_json::from_slice(&std::fs::read(root.join("settings.json")).unwrap()).unwrap();
        assert_eq!(restored, document);
    }
    #[test]
    fn invalid_configs_and_user_modified_notifiers_are_not_overwritten() {
        let f = folder();
        let root = f.0.join("codex");
        std::fs::create_dir_all(&root).unwrap();
        let base = f.0.join("data");
        let host = f.0.join("Reprise");
        std::fs::write(root.join("config.toml"), "invalid = [").unwrap();
        assert!(configure("codex", &root, &host, &base, true).is_err());
        assert_eq!(
            std::fs::read_to_string(root.join("config.toml")).unwrap(),
            "invalid = ["
        );
        assert!(!root.join("hooks.json").exists());
        std::fs::write(root.join("config.toml"), "").unwrap();
        configure("codex", &root, &host, &base, true).unwrap();
        std::fs::write(root.join("config.toml"), "notify = ['my-new-notifier']\n").unwrap();
        configure("codex", &root, &host, &base, false).unwrap();
        assert!(
            std::fs::read_to_string(root.join("config.toml"))
                .unwrap()
                .contains("my-new-notifier")
        );
    }
}
