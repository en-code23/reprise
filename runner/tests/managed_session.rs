use base64::Engine;
use serde_json::{Value, json};
use std::{
    io::{Read, Write},
    path::PathBuf,
    process::{Command, Stdio},
    time::{Duration, Instant},
};

fn managed_turns(provider: &str) -> Vec<Value> {
    managed_turns_with_outcome(provider, "success")
}
fn managed_turns_with_outcome(provider: &str, outcome: &str) -> Vec<Value> {
    let root = std::env::temp_dir().join(format!("reprise-managed-test-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&root).unwrap();
    struct Cleanup(PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = Cleanup(root.clone());
    std::fs::write(root.join("fixture.py"), include_str!("provider_fixture.py")).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let script = root.join(provider);
        std::fs::write(
            &script,
            "#!/bin/sh\nexec python3 \"$(dirname \"$0\")/fixture.py\" \"$@\"\n",
        )
        .unwrap();
        std::fs::set_permissions(script, std::fs::Permissions::from_mode(0o700)).unwrap();
    }
    #[cfg(windows)]
    std::fs::write(
        root.join(format!("{provider}.cmd")),
        "@echo off\r\npython \"%~dp0fixture.py\" %*\r\n",
    )
    .unwrap();
    let config = root.join("model-routing.json");
    std::fs::write(root.join("finish-actions.json"),json!({"enabled":true,"action":"none","delaySeconds":60,"shortcutName":"","providers":["codex","claude","grok"]}).to_string()).unwrap();
    std::fs::write(root.join("finish-monitor.json"),json!({"updatedAt":std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs_f64()}).to_string()).unwrap();
    std::fs::write(&config,json!({"preferences":{"enabled":true,"modelRoles":{"grok:grok-test-frontier":3}},"states":[],"claudeConnected":false,"fableWindowID":""}).to_string()).unwrap();
    let session = uuid::Uuid::new_v4().to_string();
    let request = json!({"provider":provider,"sessionId":session,"directory":root,"configPath":config,"projectKey":root});
    let encoded = base64::engine::general_purpose::STANDARD.encode(request.to_string());
    let paths = std::iter::once(root.clone())
        .chain(std::env::split_paths(
            &std::env::var_os("PATH").unwrap_or_default(),
        ))
        .collect::<Vec<_>>();
    let mut child = Command::new(env!("CARGO_BIN_EXE_reprise-agent"))
        .args(["run", "--request", &encoded])
        .env("PATH", std::env::join_paths(paths).unwrap())
        .env("REPRISE_TEST_PROVIDER", provider)
        .env("REPRISE_TEST_OUTCOME", outcome)
        .env("REPRISE_TEST_TRACE", root.join("trace.jsonl"))
        .env("CLAUDE_CONFIG_DIR", root.join("no-real-credentials"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let input = if provider == "claude" {
        "/model opus high\nDesign the database schema\n/model sonnet medium\nNow polish the UI layout\n/quit\n"
    } else {
        "Design the database schema\nNow polish the UI layout\n/quit\n"
    };
    child
        .stdin
        .take()
        .unwrap()
        .write_all(input.as_bytes())
        .unwrap();
    let until = Instant::now() + Duration::from_secs(20);
    loop {
        if child.try_wait().unwrap().is_some() {
            break;
        }
        if Instant::now() > until {
            let _ = child.kill();
            let output = child.wait_with_output().unwrap();
            panic!(
                "Managed fixture timed out: {} {}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    let mut output = String::new();
    child
        .stdout
        .take()
        .unwrap()
        .read_to_string(&mut output)
        .unwrap();
    let status = child.wait().unwrap();
    let mut errors = String::new();
    child
        .stderr
        .take()
        .unwrap()
        .read_to_string(&mut errors)
        .unwrap();
    assert!(status.success(), "{output}\n{errors}");
    let events = std::fs::read_dir(root.join("finish-events"))
        .unwrap()
        .map(|file| std::fs::read_to_string(file.unwrap().path()).unwrap())
        .collect::<Vec<_>>();
    let decoded = events
        .iter()
        .map(|text| serde_json::from_str::<Value>(text).unwrap())
        .collect::<Vec<_>>();
    assert_eq!(
        decoded.iter().filter(|e| e["kind"] == "completed").count(),
        if outcome == "success" { 2 } else { 0 },
        "{output}"
    );
    assert_eq!(decoded.iter().filter(|e| e["kind"] == "started").count(), 2);
    for (text, event) in events.iter().zip(&decoded) {
        assert_eq!(event["sessionId"], session);
        assert_eq!(event["provider"], provider);
        assert!(
            !text.contains("database schema")
                && !text.contains("UI layout")
                && !text.contains("accessToken")
        );
    }
    let records = std::fs::read_to_string(root.join("trace.jsonl"))
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .collect::<Vec<_>>();
    let prompts = records
        .iter()
        .filter(|p| {
            (provider == "claude" && p["type"] == "user")
                || p["method"]
                    == if provider == "codex" {
                        "turn/start"
                    } else {
                        "session/prompt"
                    }
        })
        .collect::<Vec<_>>();
    assert_eq!(prompts.len(), 2, "{output}");
    for p in prompts {
        if provider == "claude" {
            assert_eq!(p["session_id"], session);
            continue;
        }
        assert_eq!(
            p["params"][if provider == "codex" {
                "threadId"
            } else {
                "sessionId"
            }],
            session
        );
        assert!(p["params"].get("approvalPolicy").is_none());
        assert!(p["params"].get("sandboxPolicy").is_none());
    }
    assert!(
        !std::fs::read_to_string(root.join("routing-usage").join(format!("{provider}.json")))
            .unwrap()
            .contains("accessToken")
    );
    records
}

#[test]
fn failed_or_cancelled_turns_never_report_successful_completion() {
    for provider in ["codex", "claude", "grok"] {
        managed_turns_with_outcome(provider, "failed");
    }
}
#[test]
fn codex_managed_session_switches_for_new_work_without_changing_identity() {
    let records = managed_turns("codex");
    let turns = records
        .iter()
        .filter(|p| p["method"] == "turn/start")
        .collect::<Vec<_>>();
    assert_eq!(turns[0]["params"]["model"], "gpt-test-astra");
    assert_eq!(turns[0]["params"]["effort"], "high");
    assert_eq!(turns[1]["params"]["model"], "gpt-test-sol");
    assert_eq!(turns[1]["params"]["effort"], "medium");
}
#[test]
fn grok_managed_session_switches_using_advertised_configuration() {
    let records = managed_turns("grok");
    let changes = records
        .iter()
        .filter(|p| p["method"] == "session/set_config_option")
        .collect::<Vec<_>>();
    assert_eq!(changes.len(), 4);
    assert_eq!(changes[0]["params"]["value"]["value"], "grok-test-frontier");
    assert_eq!(changes[1]["params"]["value"]["value"], "high");
    assert_eq!(changes[2]["params"]["value"]["value"], "grok-test-strong");
    assert_eq!(changes[3]["params"]["value"]["value"], "medium");
}
#[test]
fn claude_managed_session_applies_acknowledged_overrides_before_user_messages() {
    let records = managed_turns("claude");
    let changes = records
        .iter()
        .filter(|p| p["request"]["subtype"] == "apply_flag_settings")
        .collect::<Vec<_>>();
    assert_eq!(changes.len(), 2);
    assert_eq!(changes[0]["request"]["settings"]["model"], "opus");
    assert_eq!(changes[0]["request"]["settings"]["effortLevel"], "high");
    assert_eq!(changes[1]["request"]["settings"]["model"], "sonnet");
    assert_eq!(changes[1]["request"]["settings"]["effortLevel"], "medium");
    let mut selected = 0;
    for record in records {
        if record["request"]["subtype"] == "apply_flag_settings" {
            selected += 1;
        }
        if record["type"] == "user" {
            assert!(selected > 0);
        }
    }
}
