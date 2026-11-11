use crate::{
    policy::{self, Assessment, Model, State, Window},
    rpc::{self, Result, Rpc},
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    path::{Path, PathBuf},
    time::Duration,
};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Request {
    pub provider: String,
    pub session_id: String,
    pub directory: PathBuf,
    pub config_path: PathBuf,
    #[serde(default)]
    pub project_key: String,
    #[serde(default)]
    pub host_probe: Option<PathBuf>,
}
impl Request {
    pub fn validate(&self) -> Result<()> {
        if !["codex", "claude", "grok"].contains(&self.provider.as_str())
            || uuid::Uuid::parse_str(&self.session_id).is_err()
        {
            return Err("Invalid provider or session identifier.".into());
        }
        if !self.directory.is_absolute()
            || !self.directory.is_dir()
            || !self.config_path.is_absolute()
        {
            return Err("Choose an existing absolute project directory.".into());
        }
        Ok(())
    }
    pub fn key(&self) -> String {
        if self.project_key.is_empty() {
            self.directory.to_string_lossy().into_owned()
        } else {
            self.project_key.clone()
        }
    }
}

#[derive(Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    #[serde(default)]
    pub preferences: policy::Preferences,
    #[serde(default)]
    pub states: Vec<State>,
    #[serde(default)]
    pub claude_connected: bool,
    #[serde(default, rename = "fableWindowID")]
    pub fable_window_id: String,
}
pub fn settings(path: &Path) -> Result<Settings> {
    if !path.exists() {
        return Ok(Settings::default());
    }
    let metadata =
        std::fs::metadata(path).map_err(|_| "Model-selection settings could not be read.")?;
    if metadata.len() > 2 * 1024 * 1024 {
        return Err("Model-selection settings exceed their size limit.".into());
    }
    serde_json::from_slice(
        &std::fs::read(path).map_err(|_| "Model-selection settings could not be read.")?,
    )
    .map_err(|_| "Model-selection settings are invalid; their original file is preserved.".into())
}
pub fn cache(path: &Path, state: &State) -> Result<()> {
    if !["codex", "claude", "grok"].contains(&state.provider.as_str()) {
        return Err("Invalid provider.".into());
    }
    let dir = path
        .parent()
        .ok_or("Invalid settings location.")?
        .join("routing-usage");
    std::fs::create_dir_all(&dir).map_err(|_| "Usage cache could not be created.")?;
    let temp = dir.join(format!("{}.{}.tmp", state.provider, uuid::Uuid::new_v4()));
    std::fs::write(
        &temp,
        serde_json::to_vec(state).map_err(|_| "Usage metadata could not be encoded.")?,
    )
    .map_err(|_| "Usage metadata could not be saved.")?;
    std::fs::rename(&temp, dir.join(format!("{}.json", state.provider)))
        .map_err(|_| "Usage metadata could not be saved.")?;
    Ok(())
}
pub fn cached(path: &Path, provider: &str) -> Option<State> {
    if !["codex", "claude", "grok"].contains(&provider) {
        return None;
    }
    let file = path
        .parent()?
        .join("routing-usage")
        .join(format!("{provider}.json"));
    if std::fs::metadata(&file).ok()?.len() > 2 * 1024 * 1024 {
        return None;
    }
    serde_json::from_slice(&std::fs::read(file).ok()?).ok()
}

pub fn date(v: &Value) -> Option<f64> {
    if let Some(n) = v.as_f64() {
        return n
            .is_finite()
            .then_some(if n > 10_000_000_000.0 { n / 1000.0 } else { n });
    }
    chrono::DateTime::parse_from_rfc3339(v.as_str()?)
        .ok()
        .map(|d| d.timestamp_millis() as f64 / 1000.0)
}
pub fn codex(catalog: &Value, usage: &Value, at: f64) -> State {
    let mut s = State {
        provider: "codex".into(),
        observed_at: Some(at),
        ..Default::default()
    };
    if let Some(rows) = catalog["data"].as_array() {
        for row in rows {
            let Some(id) = row["model"].as_str().or(row["id"].as_str()) else {
                continue;
            };
            if row["hidden"] == true {
                continue;
            }
            let efforts = row["supportedReasoningEfforts"]
                .as_array()
                .map(|a| {
                    a.iter()
                        .filter_map(|e| e["reasoningEffort"].as_str())
                        .filter(|e| policy::effort_rank(e).is_some())
                        .map(String::from)
                        .collect()
                })
                .unwrap_or_default();
            let role = if id.contains("astra") {
                3
            } else if id.contains("luna") || id.contains("mini") {
                0
            } else if id.contains("sol") || row["isDefault"] == true {
                2
            } else {
                1
            };
            let m = Model {
                id: id.into(),
                name: row["displayName"].as_str().unwrap_or(id).into(),
                role,
                efforts,
                included: true,
                ..Default::default()
            };
            if m.valid() {
                s.models.push(m);
            }
        }
    }
    // The picker may include older generations. Keep the latest advertised member
    // of each family instead of accidentally preferring an older lexical ID.
    s.models.sort_by(|a, b| {
        version_parts(&b.id)
            .cmp(&version_parts(&a.id))
            .then(a.id.cmp(&b.id))
    });
    let mut families = std::collections::HashSet::new();
    s.models.retain(|m| {
        families.insert(
            ["sol", "terra", "luna", "astra"]
                .iter()
                .find(|family| m.id.ends_with(&format!("-{family}")))
                .map(|s| s.to_string())
                .unwrap_or_else(|| m.id.clone()),
        )
    });
    let mut buckets = usage["rateLimitsByLimitId"]
        .as_object()
        .cloned()
        .unwrap_or_default();
    if buckets.is_empty() && usage["rateLimits"].is_object() {
        buckets.insert("codex".into(), usage["rateLimits"].clone());
    }
    for (id, bucket) in buckets {
        if let Some(plan) = bucket["planType"].as_str() {
            s.subscription = plan != "api";
        }
        if bucket["spendControlReached"] == true {
            s.blocked = true;
        }
        for key in ["primary", "secondary"] {
            let row = &bucket[key];
            let (Some(used), Some(reset)) = (row["usedPercent"].as_f64(), date(&row["resetsAt"]))
            else {
                continue;
            };
            let specific = bucket["normalModelSlug"]
                .as_str()
                .filter(|id| s.models.iter().any(|m| m.id == *id))
                .map(|s| vec![s.into()])
                .unwrap_or_default();
            s.windows.push(Window {
                id: format!("{id}.{key}"),
                label: format!("{} · {key}", bucket["limitName"].as_str().unwrap_or(&id)),
                used_percent: used,
                resets_at: reset,
                duration_minutes: row["windowDurationMins"].as_f64(),
                model_ids: specific,
                observed_at: at,
                ..Default::default()
            });
        }
    }
    s.blocked |= usage["ordinaryUsageAllowed"] == false;
    s.status = if s.windows.is_empty() {
        "Codex did not return usable subscription limits."
    } else {
        "Usage and available models read from Codex."
    }
    .into();
    s
}
pub fn version_parts(id: &str) -> Vec<u32> {
    id.split(|c: char| !c.is_ascii_digit())
        .filter_map(|s| s.parse().ok())
        .collect()
}
pub fn current_claude(models: Vec<Model>, catalog: &Value) -> Vec<Model> {
    let mut result = vec![];
    for role in 0..=3 {
        let preferred = match role {
            0 => "haiku",
            1 => "sonnet",
            2 => "opus",
            _ => "claude-fable-5-2",
        };
        let mut candidates = models.iter().filter(|m| m.role == role).collect::<Vec<_>>();
        candidates.sort_by(|a, b| {
            let resolved = |m: &Model| {
                catalog["models"]
                    .as_array()
                    .and_then(|rows| rows.iter().find(|r| r["value"].as_str() == Some(&m.id)))
                    .and_then(|r| r["resolvedModel"].as_str())
                    .unwrap_or(&m.id)
                    .to_string()
            };
            (b.id == preferred)
                .cmp(&(a.id == preferred))
                .then(version_parts(&resolved(b)).cmp(&version_parts(&resolved(a))))
                .then(a.id.cmp(&b.id))
        });
        if let Some(model) = candidates.first() {
            result.push((*model).clone());
        }
    }
    result
}
pub fn claude(value: &Value, subscription: bool, fable_key: &str, at: f64) -> State {
    let mut s = State {
        provider: "claude".into(),
        subscription,
        observed_at: Some(at),
        ..Default::default()
    };
    for (id, name, role, special) in [
        ("haiku", "Claude Haiku", 0, false),
        ("sonnet", "Claude Sonnet", 1, false),
        ("opus", "Claude Opus", 2, false),
        ("claude-fable-5-2", "Claude Fable 5.2", 3, true),
    ] {
        s.models.push(Model {
            id: id.into(),
            name: name.into(),
            role,
            efforts: if role >= 2 {
                vec!["low", "medium", "high", "xhigh", "max"]
            } else {
                vec!["low", "medium", "high"]
            }
            .into_iter()
            .map(String::from)
            .collect(),
            included: true,
            requires_special_allowance: special,
            ..Default::default()
        });
    }
    if let Some(rows) = value.as_object() {
        for (key, row) in rows {
            let (Some(used), Some(reset)) = (
                row["utilization"]
                    .as_f64()
                    .or(row["used_percentage"].as_f64()),
                date(&row["resets_at"]),
            ) else {
                continue;
            };
            let special = key.contains("fable") || (!fable_key.is_empty() && key == fable_key);
            let ids = if special {
                vec!["claude-fable-5-2".into()]
            } else if key == "seven_day_opus" {
                vec!["opus".into()]
            } else if key == "seven_day_sonnet" {
                vec!["sonnet".into()]
            } else {
                vec![]
            };
            s.windows.push(Window {
                id: key.clone(),
                label: if special {
                    "Fable allowance".into()
                } else {
                    key.clone()
                },
                used_percent: used,
                resets_at: reset,
                duration_minutes: if key == "five_hour" {
                    Some(300.0)
                } else if key.starts_with("seven_day") {
                    Some(10080.0)
                } else {
                    None
                },
                model_ids: ids,
                special_allowance: special,
                observed_at: at,
            });
        }
    }
    s.status = "Claude usage refreshed; Fable also requires its separate allowance.".into();
    s
}
pub fn grok_models(config: &Value, at: f64) -> State {
    fn values(v: &Value, out: &mut Vec<(String, String)>) {
        match v {
            Value::Array(items) => {
                for item in items {
                    values(item, out)
                }
            }
            Value::Object(map) => {
                if let Some(id) = map.get("value").and_then(Value::as_str) {
                    out.push((
                        id.into(),
                        map.get("name").and_then(Value::as_str).unwrap_or(id).into(),
                    ));
                }
                for (key, value) in map {
                    if key != "value" {
                        values(value, out)
                    }
                }
            }
            _ => {}
        }
    }
    let options = config["configOptions"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    let mut models = vec![];
    let mut efforts = vec![];
    for option in options {
        match option["id"].as_str() {
            Some("model") => values(&option["options"], &mut models),
            Some("reasoning_effort") => values(&option["options"], &mut efforts),
            _ => {}
        }
    }
    let efforts: Vec<String> = efforts
        .into_iter()
        .map(|(id, _)| id)
        .filter(|e| policy::effort_rank(e).is_some())
        .collect();
    let mut s = State {
        provider: "grok".into(),
        observed_at: Some(at),
        ..Default::default()
    };
    for (id, name) in models {
        let m = Model {
            role: if id.contains("fast") || id.contains("mini") {
                0
            } else {
                2
            },
            id,
            name,
            efforts: efforts.clone(),
            included: true,
            ..Default::default()
        };
        if m.valid() {
            s.models.push(m);
        }
    }
    s.status = "Grok models and efforts read from this session’s advertised capabilities.".into();
    s
}
pub fn grok_windows(value: &Value, at: f64) -> Vec<Window> {
    fn walk(v: &Value, key: &str, depth: usize, at: f64, out: &mut Vec<Window>) {
        if depth > 4 {
            return;
        }
        let (Some(used), Some(reset)) = (
            v["used_percentage"]
                .as_f64()
                .or(v["usedPercent"].as_f64())
                .or(v["utilization"].as_f64()),
            date(&v["resets_at"])
                .or(date(&v["resetsAt"]))
                .or(date(&v["reset_at"])),
        ) else {
            if let Some(map) = v.as_object() {
                for (k, v) in map {
                    if k != "extra_usage" {
                        walk(v, k, depth + 1, at, out)
                    }
                }
            }
            return;
        };
        out.push(Window {
            id: key.into(),
            label: "Grok · plan usage".into(),
            used_percent: used,
            resets_at: reset,
            duration_minutes: v["windowDurationMins"].as_f64().or(Some(10080.0)),
            observed_at: at,
            ..Default::default()
        });
    }
    let mut out = vec![];
    walk(value, "grok.weekly", 0, at, &mut out);
    out
}

pub async fn claude_usage(request: &Request, config: &Settings) -> Result<State> {
    #[cfg(not(target_os = "macos"))]
    let _ = request;
    if !config.claude_connected {
        return Err("Connect Claude usage in Reprise Settings first.".into());
    }
    #[cfg(target_os = "macos")]
    {
        let host = request
            .host_probe
            .as_ref()
            .filter(|p| p.is_file())
            .ok_or("Reprise's Claude usage bridge could not be found.")?;
        let args = vec![
            "--routing-probe".into(),
            "claude".into(),
            "--config".into(),
            request.config_path.to_string_lossy().into_owned(),
        ];
        let output = tokio::time::timeout(
            Duration::from_secs(15),
            rpc::command(host, &args, &std::env::temp_dir()).output(),
        )
        .await
        .map_err(|_| "Claude usage connection timed out.")?
        .map_err(|_| "Claude usage connection failed.")?;
        if !output.status.success() || output.stdout.len() > 2 * 1024 * 1024 {
            return Err("Claude usage could not be read; reconnect it in Reprise Settings.".into());
        }
        serde_json::from_slice(&output.stdout)
            .map_err(|_| "Claude returned invalid usage metadata.".into())
    }
    #[cfg(not(target_os = "macos"))]
    {
        let home = std::env::var_os("CLAUDE_CONFIG_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                std::env::var_os("USERPROFILE")
                    .or(std::env::var_os("HOME"))
                    .map(PathBuf::from)
                    .unwrap_or_default()
                    .join(".claude")
            });
        let file = home.join(".credentials.json");
        if std::fs::metadata(&file)
            .map_err(|_| "Sign in to Claude Code first.")?
            .len()
            > 65536
        {
            return Err("Claude login metadata is too large.".into());
        }
        let credentials: Value = serde_json::from_slice(
            &std::fs::read(file).map_err(|_| "Claude login is unavailable.")?,
        )
        .map_err(|_| "Claude login is unavailable.")?;
        let oauth = &credentials["claudeAiOauth"];
        let token = oauth["accessToken"]
            .as_str()
            .filter(|s| !s.is_empty())
            .ok_or("Sign in to Claude Code first.")?;
        if date(&oauth["expiresAt"]).is_some_and(|x| x <= policy::now()) {
            return Err("Open Claude Code to refresh its login, then retry.".into());
        }
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(10))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|_| "Usage client could not start.")?;
        let response = client
            .get("https://api.anthropic.com/api/oauth/usage")
            .bearer_auth(token)
            .header("anthropic-beta", "oauth-2025-04-20")
            .send()
            .await
            .map_err(|_| "Claude usage is unavailable.")?;
        if !response.status().is_success() || response.content_length().is_some_and(|x| x > 524288)
        {
            return Err("Claude usage is unavailable; check your CLI login.".into());
        }
        let data = response
            .bytes()
            .await
            .map_err(|_| "Claude usage could not be read.")?;
        if data.len() > 524288 {
            return Err("Claude usage response is too large.".into());
        }
        let value: Value =
            serde_json::from_slice(&data).map_err(|_| "Claude usage has an unsupported format.")?;
        let plan = oauth["subscriptionType"].as_str().unwrap_or("");
        Ok(claude(
            &value,
            ["pro", "max", "ultra", "team", "enterprise"].contains(&plan),
            &config.fable_window_id,
            policy::now(),
        ))
    }
}

pub fn apply_roles(state: &mut State, config: &Settings) {
    for model in &mut state.models {
        if let Some(role) = config
            .preferences
            .model_roles
            .get(&format!("{}:{}", state.provider, model.id))
            && *role <= 3
        {
            model.role = *role;
        }
    }
}

pub async fn probe_codex() -> Result<State> {
    let mut rpc = Rpc::start("codex", &["app-server".into()], &std::env::temp_dir()).await?;
    let _ = quiet(
        &mut rpc,
        "initialize",
        json!({"clientInfo":{"name":"reprise","title":"Reprise","version":env!("CARGO_PKG_VERSION")}}),
    )
    .await?;
    rpc.handle
        .send(json!({"method":"initialized","params":{}}))
        .await?;
    let models = quiet(
        &mut rpc,
        "model/list",
        json!({"limit":100,"includeHidden":false}),
    )
    .await?;
    let usage = quiet(&mut rpc, "account/rateLimits/read", Value::Null).await?;
    Ok(codex(&models, &usage, policy::now()))
}
pub async fn quiet(rpc: &mut Rpc, method: &str, params: Value) -> Result<Value> {
    let handle = rpc.handle.clone();
    let operation = handle.request(method, params, Duration::from_secs(30));
    tokio::pin!(operation);
    loop {
        tokio::select! {
            result=&mut operation=>return result,
            event=rpc.events.recv()=>{let event=event.ok_or("The coding tool disconnected.")?;if event.get("method").is_some()&&event.get("id").is_some(){rpc.handle.send(json!({"jsonrpc":"2.0","id":event["id"],"error":{"code":-32601,"message":"Reprise does not execute tools during metadata requests."}})).await?;}}
        }
    }
}

pub async fn grok_usage(state: &mut State) {
    for window in &mut state.windows {
        window.observed_at = 0.0;
    }
    if let Ok(bytes) = rpc::capture("grok", &["usage", "--json"], Duration::from_secs(8)).await
        && let Ok(value) = serde_json::from_slice(&bytes)
    {
        state.windows = grok_windows(&value, policy::now());
        state.subscription = !state.windows.is_empty();
    }
    state.observed_at = Some(policy::now());
    state.status=if state.windows.iter().any(|w|w.fresh(policy::now())) {"Grok plan usage refreshed."} else {"Grok plan usage is unknown. No reset capacity is assumed; automatic selection stays conservative."}.into();
}

pub fn assess(directory: &Path) -> Assessment {
    let mut a = Assessment::default();
    let mut stack = vec![directory.to_path_buf()];
    let mut entries = 0;
    let ignore = [
        ".git",
        ".hg",
        ".svn",
        "node_modules",
        "vendor",
        ".venv",
        "venv",
        ".build",
        "build",
        "dist",
        "target",
        "bin",
        "obj",
        ".next",
        "Pods",
        "DerivedData",
        "coverage",
        ".codex",
        ".claude",
        ".grok",
    ];
    while let Some(dir) = stack.pop() {
        let Ok(files) = std::fs::read_dir(dir) else {
            continue;
        };
        for file in files.flatten() {
            entries += 1;
            if entries > 12000 {
                a.truncated = true;
                break;
            }
            let Ok(kind) = file.file_type() else { continue };
            if kind.is_symlink() {
                continue;
            }
            let name = file.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') || ignore.contains(&name.as_str()) {
                continue;
            }
            let path = file.path();
            if kind.is_dir() {
                stack.push(path);
                continue;
            }
            let name = name.to_lowercase();
            let ext = path
                .extension()
                .and_then(|x| x.to_str())
                .unwrap_or("")
                .to_lowercase();
            if [
                "package.json",
                "package.swift",
                "cargo.toml",
                "go.mod",
                "pyproject.toml",
                "gemfile",
                "pom.xml",
                "composer.json",
            ]
            .contains(&name.as_str())
                || ext == "csproj"
            {
                a.manifests += 1;
            }
            if ![
                "swift", "m", "mm", "h", "cs", "fs", "go", "rs", "py", "rb", "php", "java", "kt",
                "scala", "ts", "tsx", "js", "jsx", "vue", "svelte", "html", "css", "scss", "sql",
                "graphql", "proto", "cpp", "c", "ex", "exs",
            ]
            .contains(&ext.as_str())
            {
                continue;
            }
            a.source_files += 1;
            let relative = path
                .strip_prefix(directory)
                .unwrap_or(&path)
                .to_string_lossy()
                .to_lowercase()
                .replace('\\', "/");
            let parts = relative.split('/').collect::<Vec<_>>();
            if parts
                .iter()
                .any(|p| ["test", "tests", "__tests__", "spec", "specs"].contains(p))
                || name.contains(".test.")
                || name.contains(".spec.")
                || name.ends_with("tests.swift")
            {
                a.test_files += 1;
                continue;
            }
            let ui = ["tsx", "jsx", "vue", "svelte", "css", "scss", "html"].contains(&ext.as_str())
                || parts
                    .iter()
                    .any(|p| ["views", "components", "screens", "frontend", "ui"].contains(p))
                || name.ends_with("view.swift");
            let backend = !ui
                && ([
                    "sql", "graphql", "proto", "go", "rs", "py", "rb", "php", "java", "kt", "cs",
                ]
                .contains(&ext.as_str())
                    || parts.iter().any(|p| {
                        [
                            "backend",
                            "server",
                            "api",
                            "services",
                            "migrations",
                            "database",
                            "auth",
                        ]
                        .contains(p)
                    }));
            if ui {
                a.interface_files += 1;
            }
            if backend {
                a.backend_files += 1;
            }
            if file
                .metadata()
                .ok()
                .and_then(|m| m.modified().ok())
                .and_then(|t| t.elapsed().ok())
                .is_some_and(|d| d.as_secs() < 86400)
            {
                if ui {
                    a.recent_interface_files += 1;
                }
                if backend {
                    a.recent_backend_files += 1;
                }
            }
        }
        if a.truncated {
            break;
        }
    }
    a.early_project = a.source_files < 25;
    if directory.join(".git").exists() {
        let mut git = std::process::Command::new("git");
        git.arg("-C")
            .arg(directory)
            .args(["rev-list", "--count", "--max-count=21", "HEAD"])
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            git.creation_flags(0x08000000);
        }
        if let Ok(mut child) = git.spawn() {
            let until = std::time::Instant::now() + Duration::from_secs(2);
            loop {
                match child.try_wait() {
                    Ok(Some(status)) => {
                        if status.success() {
                            if let Ok(output) = child.wait_with_output() {
                                a.early_project = String::from_utf8_lossy(&output.stdout)
                                    .trim()
                                    .parse::<usize>()
                                    .is_ok_and(|x| x <= 8);
                            }
                        } else {
                            a.early_project = true;
                        }
                        break;
                    }
                    Err(_) => break,
                    _ => {
                        if std::time::Instant::now() > until {
                            let _ = child.kill();
                            let _ = child.wait();
                            break;
                        }
                        std::thread::sleep(Duration::from_millis(10));
                    }
                }
            }
        }
    }
    a
}
