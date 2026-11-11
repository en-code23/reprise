use serde_json::{Value, json};
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    process::Stdio,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::Duration,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    process::{Child, Command},
    sync::{Mutex, mpsc, oneshot},
};

pub type Result<T> = std::result::Result<T, String>;
type Pending = Arc<Mutex<HashMap<String, oneshot::Sender<Result<Value>>>>>;

pub fn tool(name: &str) -> Result<PathBuf> {
    if !["codex", "claude", "grok", "git"].contains(&name) {
        return Err("Unsupported coding tool.".into());
    }
    let home = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
        .map(PathBuf::from)
        .unwrap_or_default();
    let mut paths: Vec<PathBuf> =
        std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()).collect();
    paths.extend([
        PathBuf::from("/opt/homebrew/bin"),
        PathBuf::from("/usr/local/bin"),
        home.join(".local/bin"),
        home.join(".cargo/bin"),
        home.join(".bun/bin"),
    ]);
    if cfg!(windows)
        && let Some(appdata) = std::env::var_os("APPDATA")
    {
        paths.push(PathBuf::from(appdata).join("npm"));
    }
    let suffixes = if cfg!(windows) {
        vec![".exe", ".cmd", ".bat", ""]
    } else {
        vec![""]
    };
    for dir in paths {
        for suffix in &suffixes {
            let file = dir.join(format!("{name}{suffix}"));
            if file.is_file() {
                return Ok(file);
            }
        }
    }
    Err(format!(
        "{name} is not installed or could not be found. Install and sign in to its CLI first."
    ))
}

pub fn command(executable: &Path, args: &[String], cwd: &Path) -> Command {
    #[cfg(windows)]
    let mut cmd = if executable
        .extension()
        .is_some_and(|x| x == "cmd" || x == "bat")
    {
        // Only allow fixed protocol/help/metadata arguments through a Windows batch shim.
        assert!(
            args.iter()
                .all(|a| !a.contains(['&', '|', '<', '>', '^', '%', '\r', '\n', '"']))
        );
        let mut c = Command::new(std::env::var("COMSPEC").unwrap_or_else(|_| "cmd.exe".into()));
        let quoted = format!(
            "\"\"{}\" {}\"",
            executable.display(),
            args.iter()
                .map(|a| format!("\"{a}\""))
                .collect::<Vec<_>>()
                .join(" ")
        );
        c.args(["/D", "/S", "/C", &quoted]);
        c
    } else {
        let mut c = Command::new(executable);
        c.args(args);
        c
    };
    #[cfg(not(windows))]
    let mut cmd = {
        let mut c = Command::new(executable);
        c.args(args);
        c
    };
    cmd.current_dir(cwd)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    #[cfg(unix)]
    {
        cmd.process_group(0);
    }
    #[cfg(windows)]
    {
        cmd.creation_flags(0x08000000);
    }
    cmd
}

#[derive(Clone)]
pub struct Handle {
    input: mpsc::Sender<Value>,
    pending: Pending,
    next: Arc<AtomicU64>,
    claude: bool,
}
impl Handle {
    pub async fn send(&self, value: Value) -> Result<()> {
        self.input
            .send(value)
            .await
            .map_err(|_| "The coding tool disconnected.".into())
    }
    pub async fn request(&self, method: &str, params: Value, timeout: Duration) -> Result<Value> {
        let id = format!("reprise-{}", self.next.fetch_add(1, Ordering::Relaxed));
        let (tx, rx) = oneshot::channel();
        self.pending.lock().await.insert(id.clone(), tx);
        let packet = if self.claude {
            json!({"type":"control_request","request_id":id,"request":params})
        } else {
            json!({"jsonrpc":"2.0","id":id,"method":method,"params":params})
        };
        if let Err(error) = self.send(packet).await {
            self.pending.lock().await.remove(&id);
            return Err(error);
        }
        let result = tokio::time::timeout(timeout, rx).await;
        self.pending.lock().await.remove(&id);
        match result { Ok(Ok(value))=>value, _=>Err("The coding tool did not answer in time. Your conversation remains in its original history.".into()) }
    }
}

pub struct Rpc {
    pub handle: Handle,
    pub events: mpsc::Receiver<Value>,
    child: Child,
    #[cfg(windows)]
    _job: std::os::windows::io::OwnedHandle,
}
impl Rpc {
    pub async fn start(provider: &str, args: &[String], cwd: &Path) -> Result<Self> {
        Self::start_executable(&tool(provider)?, args, cwd, provider == "claude").await
    }
    pub async fn start_executable(
        executable: &Path,
        args: &[String],
        cwd: &Path,
        claude: bool,
    ) -> Result<Self> {
        let mut child = command(executable, args, cwd)
            .spawn()
            .map_err(|_| "The coding tool could not start.".to_string())?;
        #[cfg(windows)]
        let job = contain_child(&child)?;
        let mut input = child
            .stdin
            .take()
            .ok_or("Could not connect to the coding tool.")?;
        let output = child
            .stdout
            .take()
            .ok_or("Could not read the coding tool.")?;
        let (tx, mut rx) = mpsc::channel::<Value>(64);
        let (events_tx, events) = mpsc::channel(256);
        let pending: Pending = Arc::new(Mutex::new(HashMap::new()));
        let reader_pending = pending.clone();
        tokio::spawn(async move {
            while let Some(packet) = rx.recv().await {
                let Ok(mut bytes) = serde_json::to_vec(&packet) else {
                    break;
                };
                bytes.push(b'\n');
                if input.write_all(&bytes).await.is_err() || input.flush().await.is_err() {
                    break;
                }
            }
        });
        tokio::spawn(async move {
            let mut reader = BufReader::new(output);
            loop {
                let mut line = Vec::new();
                // Bound a single protocol record, including large resume metadata.
                let read = (&mut reader)
                    .take(32 * 1024 * 1024 + 1)
                    .read_until(b'\n', &mut line)
                    .await;
                match read {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {}
                }
                if line.len() > 32 * 1024 * 1024 {
                    break;
                }
                let Ok(packet) = serde_json::from_slice::<Value>(&line) else {
                    continue;
                };
                let response_id = if claude && packet["type"] == "control_response" {
                    packet["response"]["request_id"].as_str()
                } else if packet.get("method").is_none() {
                    packet["id"].as_str()
                } else {
                    None
                };
                if let Some(id) = response_id
                    && let Some(waiting) = reader_pending.lock().await.remove(id)
                {
                    let result = if claude {
                        if packet["response"]["subtype"] == "error" {
                            Err("The coding tool refused that setting. Check its version, allowed models, and account access.".into())
                        } else {
                            Ok(packet["response"]["response"].clone())
                        }
                    } else if packet.get("error").is_some() {
                        Err("The coding tool refused the request. Check its login, session, version, and account access.".into())
                    } else {
                        Ok(packet["result"].clone())
                    };
                    let _ = waiting.send(result);
                    continue;
                }
                if events_tx.send(packet).await.is_err() {
                    break;
                }
            }
            for (_, waiting) in reader_pending.lock().await.drain() {
                let _ = waiting.send(Err(
                    "The coding tool disconnected. Resume it again to continue.".into(),
                ));
            }
        });
        Ok(Self {
            handle: Handle {
                input: tx,
                pending,
                next: Arc::new(AtomicU64::new(1)),
                claude,
            },
            events,
            child,
            #[cfg(windows)]
            _job: job,
        })
    }
}

#[cfg(windows)]
fn contain_child(child: &Child) -> Result<std::os::windows::io::OwnedHandle> {
    use std::os::windows::io::{FromRawHandle, OwnedHandle};
    use windows_sys::Win32::System::JobObjects::*;
    // Closing the terminal can terminate this host without running Drop. The
    // kernel closes this non-inheritable handle and terminates its process tree.
    unsafe {
        let raw = CreateJobObjectW(std::ptr::null(), std::ptr::null());
        if raw.is_null() {
            return Err("Could not contain the managed session process.".into());
        }
        let job = OwnedHandle::from_raw_handle(raw);
        let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if SetInformationJobObject(
            raw,
            JobObjectExtendedLimitInformation,
            &info as *const _ as *const _,
            std::mem::size_of_val(&info) as u32,
        ) == 0
            || AssignProcessToJobObject(
                raw,
                child
                    .raw_handle()
                    .ok_or("The coding tool already exited.")?,
            ) == 0
        {
            return Err(
                "Could not contain the managed session process. Resume in the native CLI instead."
                    .into(),
            );
        }
        Ok(job)
    }
}
impl Drop for Rpc {
    fn drop(&mut self) {
        #[cfg(unix)]
        if let Some(pid) = self.child.id() {
            unsafe {
                libc::kill(-(pid as i32), libc::SIGTERM);
            }
        }
        let _ = self.child.start_kill();
    }
}

pub async fn capture(name: &str, args: &[&str], timeout: Duration) -> Result<Vec<u8>> {
    let cwd = std::env::temp_dir();
    let args = args.iter().map(|s| s.to_string()).collect::<Vec<_>>();
    let mut child = command(&tool(name)?, &args, &cwd)
        .spawn()
        .map_err(|_| "Could not read provider metadata.".to_string())?;
    drop(child.stdin.take());
    let mut out = child.stdout.take().ok_or("No metadata output.")?;
    let mut bytes = Vec::new();
    let status = tokio::time::timeout(timeout, async {
        (&mut out)
            .take(2 * 1024 * 1024 + 1)
            .read_to_end(&mut bytes)
            .await
            .map_err(|_| "Metadata could not be read.")?;
        child.wait().await.map_err(|_| "Metadata process failed.")
    })
    .await
    .map_err(|_| "Metadata request timed out.")??;
    if bytes.len() > 2 * 1024 * 1024 || !status.success() {
        return Err("Provider usage is not available here.".into());
    }
    Ok(bytes)
}

#[cfg(test)]
pub mod tests {
    use super::*;
    pub async fn fake(claude: bool) -> Rpc {
        Rpc::start_executable(
            &std::env::current_exe().unwrap(),
            &[
                "--exact".into(),
                "rpc::tests::fake_server".into(),
                "--ignored".into(),
                "--nocapture".into(),
            ],
            &std::env::temp_dir(),
            claude,
        )
        .await
        .unwrap()
    }
    // A separate test process exercises real pipes, framing, EOF, and interleaved requests.
    #[test]
    #[ignore = "protocol fixture, invoked only by parent tests"]
    fn fake_server() {
        use std::io::{BufRead, Write};
        println!();
        let mut pending: Option<Value> = None;
        let mut model = String::new();
        for line in std::io::stdin().lock().lines() {
            let Ok(line) = line else { break };
            let Ok(p): std::result::Result<Value, _> = serde_json::from_str(&line) else {
                continue;
            };
            let response = if p["type"] == "control_request" {
                if p["request"]["subtype"] == "apply_flag_settings" {
                    model = p["request"]["settings"]["model"]
                        .as_str()
                        .unwrap_or("")
                        .into();
                }
                json!({"type":"control_response","response":{"subtype":"success","request_id":p["request_id"],"response":{"received":p["request"],"model":model}}})
            } else if p["type"] == "user" {
                json!({"type":"result","session_id":p["session_id"],"is_error":false,"model":model})
            } else if p["id"] == "approval" && p.get("method").is_none() {
                let original = pending.take().unwrap();
                json!({"id":original["id"],"result":p["result"]})
            } else {
                match p["method"].as_str().unwrap_or("") {
                    "stall" => continue,
                    "disconnect" => std::process::exit(0),
                    "reject" => {
                        json!({"id":p["id"],"error":{"code":-32000,"message":"private provider detail"}})
                    }
                    "approval_probe" => {
                        pending = Some(p);
                        json!({"id":"approval","method":"item/commandExecution/requestApproval","params":{"command":"echo fixture"}})
                    }
                    "turn/start" => {
                        // Completion can arrive before the start acknowledgement.
                        println!(
                            "{}",
                            json!({"method":"turn/completed","params":{"threadId":p["params"]["threadId"],"turn":{"id":"turn-fixture","status":"completed"}}})
                        );
                        json!({"id":p["id"],"result":{"turn":{"id":"turn-fixture"},"received":p["params"]}})
                    }
                    _ => json!({"id":p["id"],"result":{"received":p["params"]}}),
                }
            };
            println!("{response}");
            std::io::stdout().flush().unwrap();
        }
        std::process::exit(0);
    }
    #[tokio::test]
    async fn rpc_interleaves_permissions_and_preserves_request_ids() {
        let mut rpc = fake(false).await;
        let handle = rpc.handle.clone();
        let call = handle.request("approval_probe", json!({}), Duration::from_secs(3));
        tokio::pin!(call);
        let event = tokio::select! {r=&mut call=>panic!("Unexpected response: {r:?}"),e=rpc.events.recv()=>e.unwrap()};
        rpc.handle
            .send(crate::session::permission_reply("codex", &event, false))
            .await
            .unwrap();
        assert_eq!(call.await.unwrap()["decision"], "decline");
        assert!(
            rpc.handle
                .request("reject", Value::Null, Duration::from_secs(2))
                .await
                .is_err()
        );
    }
    #[tokio::test]
    async fn disconnect_and_timeout_complete_pending_calls() {
        let rpc = fake(false).await;
        assert!(
            rpc.handle
                .request("stall", Value::Null, Duration::from_millis(80))
                .await
                .is_err()
        );
        assert!(rpc.handle.pending.lock().await.is_empty());
        assert!(
            rpc.handle
                .request("disconnect", Value::Null, Duration::from_secs(2))
                .await
                .is_err()
        );
    }
    #[tokio::test]
    async fn claude_model_changes_are_acknowledged_before_next_turn() {
        let mut rpc = fake(true).await;
        for model in ["opus", "sonnet"] {
            let response=rpc.handle.request("apply_flag_settings",json!({"subtype":"apply_flag_settings","settings":{"model":model,"effortLevel":"medium"}}),Duration::from_secs(2)).await.unwrap();
            assert_eq!(response["model"], model);
            rpc.handle
                .send(crate::session::turn_request(
                    "claude",
                    "original-session",
                    "task",
                    &crate::policy::Decision::default(),
                ))
                .await
                .unwrap();
            let finished = tokio::time::timeout(Duration::from_secs(2), rpc.events.recv())
                .await
                .unwrap()
                .unwrap();
            assert_eq!(finished["session_id"], "original-session");
            assert_eq!(finished["model"], model);
        }
    }
}
