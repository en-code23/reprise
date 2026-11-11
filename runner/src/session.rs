use crate::{
    console::{self, Console},
    policy::{self, Decision, Model, State},
    providers::{self, Request, Settings},
    rpc::{Result, Rpc},
};
use fs2::FileExt;
use serde_json::{Value, json};
use std::time::Duration;

pub fn permission_reply(provider: &str, packet: &Value, allow: bool) -> Value {
    if provider == "claude" {
        let response = if allow {
            json!({"behavior":"allow","updatedInput":packet["request"]["input"]})
        } else {
            json!({"behavior":"deny","message":"The user declined this permission."})
        };
        return json!({"type":"control_response","response":{"subtype":"success","request_id":packet["request_id"],"response":response}});
    }
    if provider == "grok" {
        let choice = packet["params"]["options"].as_array().and_then(|options| {
            options
                .iter()
                .find(|o| o["kind"] == if allow { "allow_once" } else { "reject_once" })
        });
        let outcome = choice
            .map(|c| json!({"outcome":"selected","optionId":c["optionId"]}))
            .unwrap_or(json!({"outcome":"cancelled"}));
        return json!({"jsonrpc":"2.0","id":packet["id"],"result":{"outcome":outcome}});
    }
    let method = packet["method"].as_str().unwrap_or("");
    if method == "item/permissions/requestApproval" {
        return json!({"jsonrpc":"2.0","id":packet["id"],"result":{"permissions":if allow{packet["params"]["permissions"].clone()}else{json!({})},"scope":"turn"}});
    }
    json!({"jsonrpc":"2.0","id":packet["id"],"result":{"decision":if allow{"accept"}else{"decline"}}})
}

pub fn turn_request(provider: &str, id: &str, prompt: &str, decision: &Decision) -> Value {
    match provider {
        "codex" => {
            let mut v = json!({"threadId":id,"input":[{"type":"text","text":prompt}]});
            if let (Some(model), Some(effort)) = (&decision.model, &decision.effort) {
                v["model"] = json!(model.id);
                v["effort"] = json!(effort);
            }
            v
        }
        "claude" => {
            json!({"type":"user","session_id":id,"message":{"role":"user","content":[{"type":"text","text":prompt}]},"parent_tool_use_id":null})
        }
        _ => json!({"sessionId":id,"prompt":[{"type":"text","text":prompt}]}),
    }
}

struct Agent {
    rpc: Rpc,
    provider: String,
    id: String,
    state: State,
    catalog: Value,
    active_turn: Option<String>,
    streamed: bool,
    completed: bool,
}
impl Agent {
    async fn connect(request: &Request, console: &Console) -> Result<Self> {
        let args: Vec<String> = match request.provider.as_str() {
            "codex" => vec!["app-server".into()],
            "claude" => [
                "--resume",
                &request.session_id,
                "--print",
                "--input-format",
                "stream-json",
                "--output-format",
                "stream-json",
                "--verbose",
                "--include-partial-messages",
                "--permission-prompt-tool",
                "stdio",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect(),
            "grok" => vec!["agent".into(), "--no-leader".into(), "stdio".into()],
            _ => return Err("Unsupported provider.".into()),
        };
        let rpc = Rpc::start(&request.provider, &args, &request.directory).await?;
        let mut a = Agent {
            rpc,
            provider: request.provider.clone(),
            id: request.session_id.clone(),
            state: State {
                provider: request.provider.clone(),
                ..Default::default()
            },
            catalog: Value::Null,
            active_turn: None,
            streamed: false,
            completed: false,
        };
        match request.provider.as_str() {
            "codex" => {
                a.call("initialize",json!({"clientInfo":{"name":"reprise","title":"Reprise managed sessions","version":env!("CARGO_PKG_VERSION")}}),console,false).await?;
                a.rpc
                    .handle
                    .send(json!({"method":"initialized","params":{}}))
                    .await?;
                a.catalog = a
                    .call(
                        "model/list",
                        json!({"limit":100,"includeHidden":false}),
                        console,
                        false,
                    )
                    .await?;
                let loaded = a
                    .call(
                        "thread/resume",
                        json!({"threadId":a.id,"cwd":request.directory}),
                        console,
                        false,
                    )
                    .await?;
                if loaded["thread"]["status"]["type"] == "active" {
                    return Err("This Codex conversation is already working. Stop its active turn before resuming it here.".into());
                }
            }
            "claude" => {
                a.catalog = a
                    .call(
                        "initialize",
                        json!({"subtype":"initialize","sdkMcpServers":[]}),
                        console,
                        false,
                    )
                    .await?;
                a.state = providers::claude(&json!({}), false, "", policy::now());
                a.set_claude_catalog();
            }
            _ => {
                let initialized=a.call("initialize",json!({"protocolVersion":1,"clientInfo":{"name":"reprise","title":"Reprise","version":env!("CARGO_PKG_VERSION")},"clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false},"terminal":false}}),console,false).await?;
                if initialized["agentCapabilities"]["loadSession"] == false {
                    return Err("This Grok version cannot load existing ACP sessions. Update Grok Build first.".into());
                }
                let loaded = a
                    .call(
                        "session/load",
                        json!({"sessionId":a.id,"cwd":request.directory,"mcpServers":[]}),
                        console,
                        false,
                    )
                    .await?;
                a.state = providers::grok_models(&loaded, policy::now());
                a.catalog = loaded;
            }
        }
        Ok(a)
    }
    fn set_claude_catalog(&mut self) {
        let mut verified = vec![];
        if let Some(models) = self.catalog["models"].as_array() {
            for row in models {
                let Some(id) = row["value"].as_str() else {
                    continue;
                };
                let resolved = row["resolvedModel"].as_str().unwrap_or(id);
                let role = if resolved.contains("fable") {
                    3
                } else if resolved.contains("opus") {
                    2
                } else if resolved.contains("haiku") {
                    0
                } else {
                    1
                };
                let efforts = row["supportedEffortLevels"]
                    .as_array()
                    .map(|es| {
                        es.iter()
                            .filter_map(Value::as_str)
                            .filter(|x| policy::effort_rank(x).is_some())
                            .map(String::from)
                            .collect()
                    })
                    .unwrap_or_default();
                let model = Model {
                    id: id.into(),
                    name: row["displayName"].as_str().unwrap_or(id).into(),
                    role,
                    efforts,
                    included: true,
                    requires_special_allowance: resolved.contains("fable"),
                    ..Default::default()
                };
                if model.valid() {
                    verified.push(model);
                }
            }
        }
        self.state.models = providers::current_claude(verified, &self.catalog);
    }
    async fn call(
        &mut self,
        method: &str,
        params: Value,
        console: &Console,
        render: bool,
    ) -> Result<Value> {
        let handle = self.rpc.handle.clone();
        let operation = handle.request(method, params, Duration::from_secs(60));
        tokio::pin!(operation);
        loop {
            tokio::select! {
                result=&mut operation=>return result,
                event=self.rpc.events.recv()=>{let event=event.ok_or("The coding tool disconnected.")?;self.event(&event,console,render).await?;}
            }
        }
    }
    async fn usage(&mut self, request: &Request, config: &Settings, console: &Console) {
        let result = match self.provider.as_str() {
            "codex" => self
                .call("account/rateLimits/read", Value::Null, console, false)
                .await
                .map(|limits| providers::codex(&self.catalog, &limits, policy::now())),
            "claude" => providers::claude_usage(request, config).await.map(|mut s| {
                // Use the session's actual account catalog and advertised effort levels.
                if let Some(models) = self.catalog["models"].as_array() {
                    let mut verified = vec![];
                    for row in models {
                        let Some(id) = row["value"].as_str() else {
                            continue;
                        };
                        let resolved = row["resolvedModel"].as_str().unwrap_or(id);
                        let role = if resolved.contains("fable") {
                            3
                        } else if resolved.contains("opus") {
                            2
                        } else if resolved.contains("haiku") {
                            0
                        } else {
                            1
                        };
                        let efforts = row["supportedEffortLevels"]
                            .as_array()
                            .map(|es| {
                                es.iter()
                                    .filter_map(Value::as_str)
                                    .filter(|x| policy::effort_rank(x).is_some())
                                    .map(String::from)
                                    .collect()
                            })
                            .unwrap_or_default();
                        let m = Model {
                            id: id.into(),
                            name: row["displayName"].as_str().unwrap_or(id).into(),
                            role,
                            efforts,
                            included: true,
                            requires_special_allowance: resolved.contains("fable"),
                            ..Default::default()
                        };
                        if m.valid() {
                            for w in &mut s.windows {
                                if w.model_ids.contains(&"claude-fable-5-2".into())
                                    && m.requires_special_allowance
                                {
                                    w.model_ids.push(id.into());
                                }
                                if w.model_ids.contains(&"opus".into()) && role == 2 {
                                    w.model_ids.push(id.into());
                                }
                                if w.model_ids.contains(&"sonnet".into()) && role == 1 {
                                    w.model_ids.push(id.into());
                                }
                            }
                            verified.push(m);
                        }
                    }
                    s.models = providers::current_claude(verified, &self.catalog);
                }
                s
            }),
            _ => {
                providers::grok_usage(&mut self.state).await;
                Ok(self.state.clone())
            }
        };
        match result {
            Ok(mut state) => {
                providers::apply_roles(&mut state, config);
                self.state = state;
                let _ = providers::cache(&request.config_path, &self.state);
            }
            Err(_) => {
                if self.state.models.is_empty() {
                    self.state = providers::cached(&request.config_path, &self.provider)
                        .or_else(|| {
                            config
                                .states
                                .iter()
                                .find(|s| s.provider == self.provider)
                                .cloned()
                        })
                        .unwrap_or(self.state.clone());
                }
                self.state.status="Usage refresh failed; cached values may be stale. No quota is assumed to have reset.".into();
                self.state.observed_at = Some(policy::now());
                for window in &mut self.state.windows {
                    window.observed_at = 0.0;
                }
                providers::apply_roles(&mut self.state, config);
                let _ = providers::cache(&request.config_path, &self.state);
                println!("{}", self.state.status);
            }
        }
    }
    async fn change(&mut self, decision: &Decision, console: &Console) -> Result<()> {
        let (Some(model), Some(effort)) = (&decision.model, &decision.effort) else {
            return Ok(());
        };
        if !model.valid() || !model.efforts.contains(effort) {
            return Err("Invalid model choice.".into());
        }
        match self.provider.as_str() {
            "claude" => {
                self.call("apply_flag_settings",json!({"subtype":"apply_flag_settings","settings":{"model":model.id,"effortLevel":effort}}),console,false).await?;
            }
            "grok" => {
                let updated = self
                    .call(
                        "session/set_config_option",
                        json!({"sessionId":self.id,"configId":"model","value":{"value":model.id}}),
                        console,
                        false,
                    )
                    .await?;
                let supported = providers::grok_models(&updated, policy::now());
                if !supported.models.is_empty()
                    && !supported
                        .models
                        .iter()
                        .any(|m| m.id == model.id && m.efforts.contains(effort))
                {
                    return Err(
                        "The chosen Grok model does not advertise that effort. No prompt was sent."
                            .into(),
                    );
                }
                self.call("session/set_config_option",json!({"sessionId":self.id,"configId":"reasoning_effort","value":{"value":effort}}),console,false).await?;
            }
            _ => {}
        }
        Ok(())
    }
    async fn interrupt(&self) {
        let h = self.rpc.handle.clone();
        match self.provider.as_str() {
            "codex" => {
                if let Some(id) = &self.active_turn {
                    let _ = h
                        .request(
                            "turn/interrupt",
                            json!({"threadId":self.id,"turnId":id}),
                            Duration::from_secs(5),
                        )
                        .await;
                }
            }
            "claude" => {
                let _ = h
                    .request(
                        "interrupt",
                        json!({"subtype":"interrupt"}),
                        Duration::from_secs(5),
                    )
                    .await;
            }
            _ => {
                let _=h.send(json!({"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":self.id}})).await;
            }
        }
    }
    async fn turn(&mut self, prompt: &str, decision: &Decision, console: &Console) -> Result<()> {
        self.streamed = false;
        self.completed = false;
        let packet = turn_request(&self.provider, &self.id, prompt, decision);
        if self.provider == "claude" {
            self.rpc.handle.send(packet).await?;
            loop {
                tokio::select! {
                    signal=tokio::signal::ctrl_c()=>{if signal.is_ok(){println!("\nStopping this turn…");self.interrupt().await;}},
                    event=self.rpc.events.recv()=>{let event=event.ok_or("Claude disconnected.")?;if self.event(&event,console,true).await?{break;}}
                }
            }
        } else if self.provider == "codex" {
            let started = self.call("turn/start", packet, console, true).await?;
            self.active_turn = started["turn"]["id"].as_str().map(String::from);
            if self.completed {
                self.active_turn = None;
                return Ok(());
            }
            loop {
                tokio::select! {
                    signal=tokio::signal::ctrl_c()=>{if signal.is_ok(){println!("\nStopping this turn…");self.interrupt().await;}},
                    event=self.rpc.events.recv()=>{let event=event.ok_or("Codex disconnected.")?;if self.event(&event,console,true).await?{break;}}
                }
            }
        } else {
            let handle = self.rpc.handle.clone();
            let operation =
                handle.request("session/prompt", packet, Duration::from_secs(24 * 3600));
            tokio::pin!(operation);
            loop {
                tokio::select! {
                    result=&mut operation=>{result?;break;},
                    signal=tokio::signal::ctrl_c()=>{if signal.is_ok(){println!("\nStopping this turn…");self.interrupt().await;}},
                    event=self.rpc.events.recv()=>{let event=event.ok_or("Grok disconnected.")?;self.event(&event,console,true).await?;}
                }
            }
        }
        self.active_turn = None;
        println!();
        Ok(())
    }

    async fn event(&mut self, event: &Value, console: &Console, render: bool) -> Result<bool> {
        let method = event["method"].as_str().unwrap_or("");
        if self.provider == "claude" && event["type"] == "control_request" {
            let req = &event["request"];
            let subtype = req["subtype"].as_str().unwrap_or("");
            if subtype == "can_use_tool" {
                let tool = req["tool_name"].as_str().unwrap_or("Tool");
                if tool == "AskUserQuestion" && render {
                    let mut answers = serde_json::Map::new();
                    if let Some(questions) = req["input"]["questions"].as_array() {
                        for q in questions {
                            let question = q["question"].as_str().unwrap_or("Question");
                            if let Some(options) = q["options"].as_array() {
                                for option in options {
                                    println!(
                                        "  {} — {}",
                                        option["label"].as_str().unwrap_or(""),
                                        option["description"].as_str().unwrap_or("")
                                    );
                                }
                            }
                            answers.insert(question.into(), json!(console.answer(question).await?));
                        }
                    }
                    let mut input = req["input"].clone();
                    input["answers"] = Value::Object(answers);
                    self.rpc.handle.send(json!({"type":"control_response","response":{"subtype":"success","request_id":event["request_id"],"response":{"behavior":"allow","updatedInput":input}}})).await?;
                } else {
                    let allow = render && console.allow(&format!("{tool}\n{}", req["input"])).await;
                    self.rpc
                        .handle
                        .send(permission_reply("claude", event, allow))
                        .await?;
                }
            } else if subtype == "elicitation" && render {
                println!(
                    "{}",
                    console::clean(
                        req["message"]
                            .as_str()
                            .unwrap_or("The tool requests input."),
                        2000
                    )
                );
                self.rpc.handle.send(json!({"type":"control_response","response":{"subtype":"success","request_id":event["request_id"],"response":{"action":"decline"}}})).await?;
            } else {
                self.rpc.handle.send(json!({"type":"control_response","response":{"subtype":"error","request_id":event["request_id"],"error":"This host does not support that control request."}})).await?;
            }
            return Ok(false);
        }
        if event.get("id").is_some() && event.get("method").is_some() {
            match method {
                "item/commandExecution/requestApproval"
                | "item/fileChange/requestApproval"
                | "item/permissions/requestApproval" => {
                    let params = &event["params"];
                    let summary = format!(
                        "{}\n{}",
                        params["reason"].as_str().unwrap_or(method),
                        params["command"]
                            .as_str()
                            .map(String::from)
                            .unwrap_or_else(|| params["permissions"].to_string())
                    );
                    let allow = render && console.allow(&summary).await;
                    self.rpc
                        .handle
                        .send(permission_reply("codex", event, allow))
                        .await?;
                }
                "item/tool/requestUserInput" => {
                    let mut answers = serde_json::Map::new();
                    if render && let Some(questions) = event["params"]["questions"].as_array() {
                        for q in questions {
                            if let Some(options) = q["options"].as_array() {
                                for option in options {
                                    println!(
                                        "  {} — {}",
                                        option["label"].as_str().unwrap_or(""),
                                        option["description"].as_str().unwrap_or("")
                                    );
                                }
                            }
                            let response = console
                                .answer(q["question"].as_str().unwrap_or("Question"))
                                .await?;
                            answers.insert(
                                q["id"].as_str().unwrap_or("").into(),
                                json!({"answers":[response]}),
                            );
                        }
                    }
                    self.rpc
                        .handle
                        .send(
                            json!({"jsonrpc":"2.0","id":event["id"],"result":{"answers":answers}}),
                        )
                        .await?;
                }
                "session/request_permission" => {
                    let allow = render
                        && console
                            .allow(&event["params"]["toolCall"].to_string())
                            .await;
                    self.rpc
                        .handle
                        .send(permission_reply("grok", event, allow))
                        .await?;
                }
                _ => {
                    self.rpc.handle.send(json!({"jsonrpc":"2.0","id":event["id"],"error":{"code":-32601,"message":"Unsupported client capability. Reprise does not execute tools on the agent's behalf."}})).await?;
                }
            }
            return Ok(false);
        }
        if !render {
            return Ok(false);
        }
        if self.provider == "codex"
            && event["params"]["threadId"]
                .as_str()
                .is_some_and(|id| id != self.id)
        {
            return Ok(false);
        }
        match self.provider.as_str() {
            "codex" => match method {
                "item/agentMessage/delta" => {
                    if let Some(text) = event["params"]["delta"].as_str() {
                        console::write(text);
                        self.streamed = true;
                    }
                }
                "item/commandExecution/outputDelta" => {
                    if let Some(text) = event["params"]["delta"].as_str() {
                        console::write(text);
                    }
                }
                "item/started" => {
                    let item = &event["params"]["item"];
                    if item["type"] == "commandExecution" {
                        println!(
                            "\n$ {}",
                            console::clean(item["command"].as_str().unwrap_or("command"), 600)
                        );
                    } else if item["type"] == "fileChange" {
                        println!("\n[editing files]");
                    }
                }
                "turn/completed" => {
                    let turn = &event["params"]["turn"];
                    if turn["status"] == "failed" {
                        println!(
                            "\n{}",
                            console::clean(
                                turn["error"]["message"]
                                    .as_str()
                                    .unwrap_or("The turn failed."),
                                1500
                            )
                        );
                    }
                    self.completed = true;
                    return Ok(true);
                }
                _ => {}
            },
            "claude" => match event["type"].as_str().unwrap_or("") {
                "stream_event" => {
                    let e = &event["event"];
                    if e["type"] == "content_block_delta"
                        && e["delta"]["type"] == "text_delta"
                        && let Some(text) = e["delta"]["text"].as_str()
                    {
                        console::write(text);
                        self.streamed = true;
                    }
                }
                "assistant" => {
                    if let Some(content) = event["message"]["content"].as_array() {
                        for part in content {
                            if part["type"] == "tool_use" {
                                println!(
                                    "\n[{}]",
                                    console::clean(part["name"].as_str().unwrap_or("tool"), 120)
                                );
                            } else if part["type"] == "text"
                                && !self.streamed
                                && let Some(text) = part["text"].as_str()
                            {
                                console::write(text);
                            }
                        }
                    }
                }
                "result" => {
                    if event["is_error"] == true {
                        println!("\nThe turn failed. Check the provider's limits and CLI login.");
                    }
                    self.completed = true;
                    return Ok(true);
                }
                "system" if event["subtype"] == "task_notification" => {
                    println!("\n[background task updated]");
                }
                _ => {}
            },
            _ => {
                if method == "session/update" {
                    let update = &event["params"]["update"];
                    match update["sessionUpdate"].as_str().unwrap_or("") {
                        "agent_message_chunk" => {
                            if let Some(text) = update["content"]["text"].as_str() {
                                console::write(text);
                            }
                        }
                        "tool_call" => {
                            println!(
                                "\n[{}]",
                                console::clean(update["title"].as_str().unwrap_or("tool"), 500)
                            );
                        }
                        _ => {}
                    }
                }
            }
        }
        Ok(false)
    }
}

pub async fn run(request: Request) -> Result<()> {
    request.validate()?;
    let lock_dir = request
        .config_path
        .parent()
        .ok_or("Invalid settings directory.")?
        .join("managed-locks");
    std::fs::create_dir_all(&lock_dir).map_err(|_| "Could not reserve this managed session.")?;
    let lock = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(lock_dir.join(format!("{}-{}.lock", request.provider, request.session_id)))
        .map_err(|_| "Could not reserve this managed session.")?;
    lock.try_lock_exclusive()
        .map_err(|_| "This conversation is already open in another Reprise managed session.")?;
    println!(
        "Reprise · {} managed session\n{}\n\nModels are chosen between turns. Commands: /usage, /work auto|ui|backend|foundation|small,\n/model <id> [effort], /auto on|off, /quit. Ctrl+C stops the active turn.\n",
        request.provider,
        request.directory.display()
    );
    let console = Console::new();
    println!("Connecting to the existing conversation…");
    let mut agent = Agent::connect(&request, &console).await?;
    let initial = providers::settings(&request.config_path)?;
    agent.usage(&request, &initial, &console).await;
    let mut override_auto: Option<bool> = None;
    let mut work: Option<String> = None;
    let mut manual: Option<(String, String)> = None;
    let mut last_kind: Option<String> = None;
    loop {
        let Some(line) = console.read("You › ", true).await else {
            break;
        };
        let line = line.trim();
        if line.is_empty() || line == "/interrupt" {
            continue;
        }
        if ["/quit", "/exit"].contains(&line) {
            break;
        }
        if line == "/usage" {
            let config = providers::settings(&request.config_path)?;
            agent.usage(&request, &config, &console).await;
            print_usage(&agent.state);
            continue;
        }
        if let Some(value) = line.strip_prefix("/auto ") {
            match value.trim() {
                "on" => {
                    override_auto = Some(true);
                    manual = None;
                    println!("Automatic selection enabled for this managed session.");
                }
                "off" => {
                    override_auto = Some(false);
                    println!("Automatic model changes paused. The current model stays selected.");
                }
                _ => println!("Use /auto on or /auto off."),
            }
            continue;
        }
        if let Some(value) = line.strip_prefix("/work ") {
            let kind = match value.trim() {
                "auto" => "automatic",
                "ui" => "interface",
                "small" => "smallTask",
                other => other,
            };
            if policy::valid_kind(kind) {
                work = if kind == "automatic" {
                    last_kind = None;
                    None
                } else {
                    Some(kind.into())
                };
                println!("Work type: {kind}");
            } else {
                println!("Use /work auto, ui, backend, foundation, or small.");
            }
            continue;
        }
        if let Some(value) = line.strip_prefix("/model ") {
            let parts = value.split_whitespace().collect::<Vec<_>>();
            if let Some(model) = parts
                .first()
                .and_then(|id| agent.state.models.iter().find(|m| m.id == *id))
            {
                let effort = parts.get(1).copied().unwrap_or("medium");
                if model.efforts.contains(&effort.to_string()) {
                    manual = Some((model.id.clone(), effort.into()));
                    println!(
                        "Manual model selected for following turns. Use /auto on to return to automatic selection."
                    );
                } else {
                    println!("Supported efforts: {}", model.efforts.join(", "));
                }
            } else {
                println!(
                    "Available models: {}",
                    agent
                        .state
                        .models
                        .iter()
                        .map(|m| m.id.as_str())
                        .collect::<Vec<_>>()
                        .join(", ")
                );
            }
            continue;
        }
        let config = providers::settings(&request.config_path)?;
        agent.usage(&request, &config, &console).await;
        let dir = request.directory.clone();
        let project = tokio::task::spawn_blocking(move || providers::assess(&dir))
            .await
            .map_err(|_| "Project assessment failed.")?;
        let mut prefs = config.preferences.clone();
        if let Some(enabled) = override_auto {
            prefs.enabled = enabled;
        }
        if prefs.disabled_projects.contains(&request.key()) {
            prefs.enabled = false;
        }
        let saved = config
            .preferences
            .work_hints
            .get(&request.key())
            .map(String::as_str)
            .unwrap_or("automatic");
        let hint = work.clone().unwrap_or_else(|| {
            if saved != "automatic" {
                saved.into()
            } else {
                policy::prompt_kind(
                    line,
                    last_kind.as_deref().unwrap_or(&project.kind("automatic")),
                )
            }
        });
        let mut decision = policy::decide(&project, &agent.state, &prefs, &hint, policy::now());
        if let Some((id, effort)) = &manual
            && let Some(model) = agent
                .state
                .models
                .iter()
                .find(|m| m.id == *id && m.efforts.contains(effort))
        {
            decision = Decision {
                model: Some(model.clone()),
                effort: Some(effort.clone()),
                kind: hint,
                reasons: vec!["Manual model override.".into()],
                ..Default::default()
            };
        }
        if decision.blocked {
            println!(
                "{}\nNo prompt was sent. Check /usage or wait for a reset.",
                decision.reasons.join(" ")
            );
            continue;
        }
        if let (Some(model), Some(effort)) = (&decision.model, &decision.effort) {
            println!(
                "\n{} · {}{}\n{}\n",
                model.name,
                effort,
                if decision.boosted {
                    " · reset headroom"
                } else {
                    ""
                },
                decision.reasons.join(" ")
            );
        } else {
            println!(
                "\nUsing the coding tool’s current model. {}\n",
                decision.reasons.join(" ")
            );
        }
        if let Err(error) = agent.change(&decision, &console).await {
            println!(
                "Could not apply model selection: {error}\nNo prompt was sent. Use /auto off to keep the tool’s current settings."
            );
            continue;
        }
        last_kind = Some(decision.kind.clone());
        if let Err(error) = agent.turn(line, &decision, &console).await {
            println!("\n{error}");
            break;
        }
    }
    println!(
        "Session closed. Its original conversation history is kept by {}.",
        request.provider
    );
    Ok(())
}
fn print_usage(state: &State) {
    println!("{}", state.status);
    for w in &state.windows {
        let seconds = (w.resets_at - policy::now()).max(0.0) as u64;
        println!(
            "{}: {:.0}% left · resets in {}h {}m{}",
            w.label,
            w.remaining(),
            seconds / 3600,
            (seconds % 3600) / 60,
            if w.fresh(policy::now()) {
                ""
            } else {
                " · stale / refresh required"
            }
        );
    }
    if state.windows.is_empty() {
        println!("Usage is unknown. No remaining allowance or reset is assumed.");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn two_codex_turns_keep_identity_and_handle_early_completion() {
        let mut agent = Agent {
            rpc: crate::rpc::tests::fake(false).await,
            provider: "codex".into(),
            id: "original-thread".into(),
            state: State::default(),
            catalog: Value::Null,
            active_turn: None,
            streamed: false,
            completed: false,
        };
        let console = Console::new();
        for id in ["strong", "everyday"] {
            let decision = Decision {
                model: Some(Model {
                    id: id.into(),
                    name: id.into(),
                    role: 1,
                    efforts: vec!["medium".into()],
                    included: true,
                    ..Default::default()
                }),
                effort: Some("medium".into()),
                ..Default::default()
            };
            tokio::time::timeout(
                Duration::from_secs(3),
                agent.turn("fixture task", &decision, &console),
            )
            .await
            .unwrap()
            .unwrap();
            assert_eq!(agent.id, "original-thread");
            assert!(agent.active_turn.is_none());
        }
        assert!(!agent.event(&json!({"method":"turn/completed","params":{"threadId":"child-thread","turn":{"status":"completed"}}}),&console,true).await.unwrap());
    }
    #[test]
    fn approval_is_explicit_and_never_changes_policy() {
        let p = json!({"id":77,"method":"item/commandExecution/requestApproval","params":{"command":"write a file"}});
        assert_eq!(
            permission_reply("codex", &p, false)["result"]["decision"],
            "decline"
        );
        assert_eq!(
            permission_reply("codex", &p, true)["result"]["decision"],
            "accept"
        );
        let c = json!({"type":"control_request","request_id":"p1","request":{"subtype":"can_use_tool","input":{"command":"echo hello"}}});
        let denied = permission_reply("claude", &c, false);
        assert_eq!(denied["response"]["request_id"], "p1");
        assert_eq!(denied["response"]["response"]["behavior"], "deny");
        let acp = json!({"id":9,"params":{"options":[{"kind":"allow_always","optionId":"dangerous"},{"kind":"reject_once","optionId":"no"}]}});
        assert_eq!(
            permission_reply("grok", &acp, true)["result"]["outcome"]["outcome"],
            "cancelled"
        );
    }
    #[test]
    fn model_override_preserves_conversation_and_does_not_widen_sandbox() {
        let d = Decision {
            model: Some(Model {
                id: "gpt-test".into(),
                name: "Test".into(),
                role: 2,
                efforts: vec!["high".into()],
                included: true,
                ..Default::default()
            }),
            effort: Some("high".into()),
            ..Default::default()
        };
        let packet = turn_request("codex", "same-thread", "Build the API", &d);
        assert_eq!(packet["threadId"], "same-thread");
        assert_eq!(packet["model"], "gpt-test");
        assert_eq!(packet["effort"], "high");
        assert!(packet.get("approvalPolicy").is_none());
        assert!(packet.get("sandboxPolicy").is_none());
        let claude = turn_request("claude", "same-thread", "Now polish UI", &d);
        assert_eq!(claude["session_id"], "same-thread");
    }
}
