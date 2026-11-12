use base64::Engine;
use serde_json::{Value, json};
use std::{
    io::Write,
    process::{Command, Stdio},
    time::{Duration, Instant},
};

#[test]
fn background_completion_is_reported_while_waiting_for_input() {
    let root =
        std::env::temp_dir().join(format!("reprise-background-test-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&root).unwrap();
    struct Cleanup(std::path::PathBuf);
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
        let file = root.join("claude");
        std::fs::write(
            &file,
            "#!/bin/sh\nexec python3 \"$(dirname \"$0\")/fixture.py\" \"$@\"\n",
        )
        .unwrap();
        std::fs::set_permissions(file, std::fs::Permissions::from_mode(0o700)).unwrap();
    }
    #[cfg(windows)]
    std::fs::write(
        root.join("claude.cmd"),
        "@echo off\r\npython \"%~dp0fixture.py\" %*\r\n",
    )
    .unwrap();
    let config = root.join("model-routing.json");
    std::fs::write(
        &config,
        json!({"preferences":{"enabled":false},"states":[],"claudeConnected":false}).to_string(),
    )
    .unwrap();
    std::fs::write(
        root.join("finish-actions.json"),
        json!({"enabled":true}).to_string(),
    )
    .unwrap();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs_f64();
    std::fs::write(
        root.join("finish-monitor.json"),
        json!({"updatedAt":now}).to_string(),
    )
    .unwrap();
    let request = json!({"provider":"claude","sessionId":uuid::Uuid::new_v4().to_string(),"directory":root,"configPath":config});
    let paths = std::iter::once(root.clone())
        .chain(std::env::split_paths(
            &std::env::var_os("PATH").unwrap_or_default(),
        ))
        .collect::<Vec<_>>();
    let mut child = Command::new(env!("CARGO_BIN_EXE_reprise-agent"))
        .args([
            "run",
            "--request",
            &base64::engine::general_purpose::STANDARD.encode(request.to_string()),
        ])
        .env("PATH", std::env::join_paths(paths).unwrap())
        .env("REPRISE_TEST_PROVIDER", "claude")
        .env("REPRISE_TEST_BACKGROUND", "1")
        .env("REPRISE_TEST_TRACE", root.join("trace.jsonl"))
        .env("CLAUDE_CONFIG_DIR", root.join("no-credentials"))
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    input.write_all(b"Run the background work\n").unwrap();
    input.flush().unwrap();
    let until = Instant::now() + Duration::from_secs(10);
    let mut completed = false;
    while Instant::now() < until {
        if let Ok(files) = std::fs::read_dir(root.join("finish-events")) {
            completed = files
                .flatten()
                .filter(|f| f.path().extension().is_some_and(|x| x == "json"))
                .filter_map(|f| std::fs::read(f.path()).ok())
                .filter_map(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
                .any(|e| e["kind"] == "completed" && e["backgroundWork"] == false);
            if completed {
                break;
            }
        }
        if child.try_wait().unwrap().is_some() {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    if !completed {
        let _ = child.kill();
        let _ = child.wait();
        panic!("Completion was not reported until further user input.");
    }
    input.write_all(b"/quit\n").unwrap();
    drop(input);
    let until = Instant::now() + Duration::from_secs(5);
    loop {
        if child.try_wait().unwrap().is_some() {
            break;
        }
        if Instant::now() > until {
            let _ = child.kill();
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    let _ = child.wait();
}
