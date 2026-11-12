use crate::{providers::Request, rpc::Result};
use serde_json::json;
use std::path::PathBuf;

/// Writes lifecycle metadata only. The Mac application owns arming and execution.
pub struct Emitter {
    base: PathBuf,
    provider: String,
    session: String,
    pub turn: Option<String>,
}
impl Emitter {
    pub fn new(request: &Request) -> Self {
        Self {
            base: request
                .config_path
                .parent()
                .unwrap_or(&request.config_path)
                .to_path_buf(),
            provider: request.provider.clone(),
            session: request.session_id.clone(),
            turn: None,
        }
    }
    pub fn start(&mut self) {
        self.turn = Some(uuid::Uuid::new_v4().to_string());
        self.emit("started", false, None);
    }
    pub fn emit(&self, kind: &str, background: bool, child: Option<&str>) {
        let _ = self.write(kind, background, child);
    }
    fn write(&self, kind: &str, background: bool, child: Option<&str>) -> Result<()> {
        let preferences = self.base.join("finish-actions.json");
        if std::fs::metadata(&preferences)
            .map(|m| m.len() > 65536)
            .unwrap_or(true)
        {
            return Ok(());
        }
        let preferences: serde_json::Value = serde_json::from_slice(
            &std::fs::read(preferences).map_err(|_| "Preferences unavailable.")?,
        )
        .map_err(|_| "Invalid preferences.")?;
        if preferences["enabled"] != true {
            return Ok(());
        }
        let lease = self.base.join("finish-monitor.json");
        if std::fs::metadata(&lease)
            .map(|m| m.len() > 1024)
            .unwrap_or(true)
        {
            return Ok(());
        }
        let lease: serde_json::Value =
            serde_json::from_slice(&std::fs::read(lease).map_err(|_| "Monitor unavailable.")?)
                .map_err(|_| "Monitor unavailable.")?;
        let Some(updated) = lease["updatedAt"].as_f64() else {
            return Ok(());
        };
        let now = crate::policy::now();
        if updated > now + 5.0 || now - updated >= 15.0 {
            return Ok(());
        }
        let queue = self.base.join("finish-events");
        if std::fs::symlink_metadata(&queue).is_ok_and(|m| m.file_type().is_symlink()) {
            return Ok(());
        }
        std::fs::create_dir_all(&queue).map_err(|_| "Completion events unavailable.")?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&queue, std::fs::Permissions::from_mode(0o700));
        }
        let id = uuid::Uuid::new_v4().to_string();
        let data = json!({"id":id,"provider":self.provider,"sessionId":self.session,"turnId":self.turn,
            "kind":kind,"source":"managed","occurredAt":crate::policy::now(),"childId":child,"backgroundWork":background});
        let temporary = queue.join(format!("{id}.tmp"));
        use std::io::Write;
        let mut options = std::fs::OpenOptions::new();
        options.create_new(true).write(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options
            .open(&temporary)
            .map_err(|_| "Completion event could not be saved.")?;
        file.write_all(data.to_string().as_bytes())
            .map_err(|_| "Completion event could not be saved.")?;
        drop(file);
        std::fs::rename(temporary, queue.join(format!("{id}.json")))
            .map_err(|_| "Completion event could not be saved.".into())
    }
}
impl Drop for Emitter {
    fn drop(&mut self) {
        self.emit("closed", false, None);
    }
}
