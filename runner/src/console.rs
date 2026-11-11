use crate::rpc::Result;
use std::io::Write;
use tokio::sync::oneshot;

struct Read {
    prompt: String,
    history: bool,
    reply: oneshot::Sender<Option<String>>,
}
pub struct Console {
    sender: std::sync::mpsc::Sender<Read>,
}
impl Console {
    pub fn new() -> Self {
        let (tx, rx) = std::sync::mpsc::channel::<Read>();
        std::thread::spawn(move || {
            let Ok(mut editor) = rustyline::DefaultEditor::new() else {
                return;
            };
            while let Ok(read) = rx.recv() {
                let line = match editor.readline(&read.prompt) {
                    Ok(line) => {
                        if read.history && !line.trim().is_empty() {
                            let _ = editor.add_history_entry(&line);
                        }
                        Some(line)
                    }
                    Err(rustyline::error::ReadlineError::Interrupted) => Some("/interrupt".into()),
                    _ => None,
                };
                let _ = read.reply.send(line);
            }
        });
        Self { sender: tx }
    }
    pub async fn read(&self, prompt: &str, history: bool) -> Option<String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(Read {
                prompt: prompt.into(),
                history,
                reply: tx,
            })
            .ok()?;
        rx.await.ok().flatten()
    }
    pub async fn allow(&self, description: &str) -> bool {
        let code = &uuid::Uuid::new_v4().simple().to_string()[..4];
        println!(
            "\nPermission requested by the coding tool:\n{}",
            clean(description, 2000)
        );
        let answer = self
            .read(
                &format!("Type 'allow {code}' to allow once; Enter denies: "),
                false,
            )
            .await;
        answer.is_some_and(|x| x.trim() == format!("allow {code}"))
    }
    pub async fn answer(&self, label: &str) -> Result<String> {
        self.read(&format!("{}: ", clean(label, 500)), false)
            .await
            .filter(|x| x != "/interrupt")
            .ok_or("Input cancelled.".into())
    }
}
pub fn clean(text: &str, limit: usize) -> String {
    text.chars()
        .filter(|c| !c.is_control() || *c == '\n' || *c == '\t')
        .take(limit)
        .collect()
}
pub fn write(text: &str) {
    print!("{}", clean(text, 1_000_000));
    let _ = std::io::stdout().flush();
}
