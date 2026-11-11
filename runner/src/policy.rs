use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};

pub fn now() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}
fn yes() -> bool {
    true
}
fn reserve() -> f64 {
    20.0
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Preferences {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default = "reserve")]
    pub reserve_percent: f64,
    #[serde(default = "yes")]
    pub use_expiring_headroom: bool,
    #[serde(default)]
    pub allow_foundation_max: bool,
    #[serde(default)]
    pub use_fable_allowance: bool,
    #[serde(default)]
    pub work_hints: HashMap<String, String>,
    #[serde(default)]
    pub model_roles: HashMap<String, u8>,
    #[serde(default)]
    pub disabled_projects: HashSet<String>,
    #[serde(default = "yes")]
    pub continuous: bool,
}
impl Default for Preferences {
    fn default() -> Self {
        Self {
            enabled: false,
            reserve_percent: reserve(),
            use_expiring_headroom: true,
            allow_foundation_max: false,
            use_fable_allowance: false,
            work_hints: HashMap::new(),
            model_roles: HashMap::new(),
            disabled_projects: HashSet::new(),
            continuous: true,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Model {
    pub id: String,
    pub name: String,
    pub role: u8,
    pub efforts: Vec<String>,
    #[serde(default, rename = "quotaIDs")]
    pub quota_ids: Vec<String>,
    #[serde(default = "yes")]
    pub included: bool,
    #[serde(default)]
    pub requires_special_allowance: bool,
}
impl Model {
    pub fn valid(&self) -> bool {
        !self.id.is_empty()
            && self.id.len() <= 120
            && self.id.as_bytes()[0].is_ascii_alphanumeric()
            && self
                .id
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || b"_.:/-".contains(&c))
            && self.role <= 3
            && !self.efforts.is_empty()
            && self.efforts.iter().all(|x| effort_rank(x).is_some())
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Window {
    pub id: String,
    pub label: String,
    pub used_percent: f64,
    pub resets_at: f64,
    #[serde(default)]
    pub duration_minutes: Option<f64>,
    #[serde(default, rename = "modelIDs")]
    pub model_ids: Vec<String>,
    #[serde(default)]
    pub special_allowance: bool,
    pub observed_at: f64,
}
impl Window {
    pub fn fresh(&self, at: f64) -> bool {
        self.used_percent.is_finite()
            && (0.0..=100.0).contains(&self.used_percent)
            && self.observed_at <= at + 60.0
            && at - self.observed_at <= 300.0
            && self.resets_at > at
    }
    pub fn remaining(&self) -> f64 {
        (100.0 - self.used_percent).max(0.0)
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct State {
    pub provider: String,
    #[serde(default)]
    pub models: Vec<Model>,
    #[serde(default)]
    pub windows: Vec<Window>,
    pub observed_at: Option<f64>,
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub subscription: bool,
    #[serde(default)]
    pub blocked: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Assessment {
    pub source_files: usize,
    pub backend_files: usize,
    pub interface_files: usize,
    pub test_files: usize,
    pub manifests: usize,
    pub early_project: bool,
    #[serde(default)]
    pub recent_backend_files: usize,
    #[serde(default)]
    pub recent_interface_files: usize,
    #[serde(default)]
    pub truncated: bool,
}
impl Assessment {
    pub fn large(&self) -> bool {
        self.source_files >= 180 || self.manifests >= 5
    }
    pub fn kind(&self, hint: &str) -> String {
        if valid_kind(hint) && hint != "automatic" {
            return hint.into();
        }
        if self.early_project
            && self.backend_files > 0
            && self.test_files < 4_usize.max(self.backend_files / 10)
            && (self.interface_files == 0
                || self.recent_backend_files > self.recent_interface_files)
        {
            return "foundation".into();
        }
        if self.recent_interface_files > self.recent_backend_files {
            return "interface".into();
        }
        if self.recent_backend_files > self.recent_interface_files {
            return "backend".into();
        }
        if self.interface_files > self.backend_files {
            return "interface".into();
        }
        if self.backend_files > 0 {
            "backend".into()
        } else {
            "smallTask".into()
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Decision {
    pub model: Option<Model>,
    pub effort: Option<String>,
    pub kind: String,
    pub reasons: Vec<String>,
    pub constrained: bool,
    pub blocked: bool,
    pub boosted: bool,
}

pub fn valid_kind(kind: &str) -> bool {
    [
        "automatic",
        "smallTask",
        "interface",
        "backend",
        "foundation",
    ]
    .contains(&kind)
}
pub fn effort_rank(effort: &str) -> Option<usize> {
    ["low", "medium", "high", "xhigh", "max"]
        .iter()
        .position(|e| *e == effort)
}

pub fn prompt_kind(prompt: &str, fallback: &str) -> String {
    let p = prompt.to_lowercase();
    let has = |words: &[&str]| words.iter().any(|s| p.contains(s));
    if has(&[
        "architecture",
        "architect ",
        "database schema",
        "backend foundation",
        "initial backend",
        "build the backend",
        "design the backend",
        "data model",
        "auth system",
        "authentication system",
    ]) {
        return "foundation".into();
    }
    let backend = has(&[
        "database",
        "migration",
        "deadlock",
        "backend",
        "api endpoint",
        "server",
        "authentication",
        "authorization",
        "sql ",
    ]);
    let ui = has(&[
        " ui",
        "ui ",
        "frontend",
        "front-end",
        "layout",
        "css",
        "component",
        "screen",
        "visual",
        "spacing",
        "button",
        "icon",
        "design",
    ]);
    if backend {
        return "backend".into();
    }
    if ui {
        return "interface".into();
    }
    if has(&[
        "typo",
        "spelling",
        "rename ",
        "comment only",
        "small change",
    ]) {
        return "smallTask".into();
    }
    fallback.into()
}

pub fn decide(
    project: &Assessment,
    state: &State,
    preferences: &Preferences,
    hint: &str,
    at: f64,
) -> Decision {
    let kind = project.kind(hint);
    let mut d = Decision {
        kind: kind.clone(),
        ..Default::default()
    };
    if !preferences.enabled {
        d.reasons.push("Automatic selection is off.".into());
        return d;
    }
    if state.blocked {
        d.blocked = true;
        d.reasons
            .push("The provider reports that included usage is unavailable.".into());
        return d;
    }
    let models: Vec<_> = state
        .models
        .iter()
        .filter(|m| m.valid() && m.included)
        .collect();
    if models.is_empty() {
        d.blocked = true;
        d.reasons
            .push("No verified model is available. Refresh its catalog or explicitly turn off automatic selection.".into());
        return d;
    }
    let shared: Vec<_> = state
        .windows
        .iter()
        .filter(|w| w.model_ids.is_empty() && !w.special_allowance)
        .collect();
    let fresh = !shared.is_empty() && shared.iter().all(|w| w.fresh(at));
    if shared
        .iter()
        .any(|w| w.fresh(at) && w.used_percent >= 100.0)
    {
        d.blocked = true;
        d.reasons
            .push("A shared usage limit is exhausted. Refresh after its reset.".into());
        return d;
    }
    let reserve = if preferences.reserve_percent.is_finite() {
        preferences.reserve_percent.clamp(5.0, 50.0)
    } else {
        20.0
    };
    let headroom = if fresh {
        shared.iter().map(|w| w.remaining()).fold(100.0, f64::min)
    } else {
        0.0
    };
    let pace_tight = fresh
        && shared.iter().any(|w| {
            w.duration_minutes.is_some_and(|minutes| {
                let time_left = ((w.resets_at - at) / (minutes * 60.0)).min(1.0);
                minutes > 0.0
                    && time_left > 0.2
                    && (w.remaining() - reserve) / 100.0 < time_left * (1.0 - reserve / 100.0) * 0.6
            })
        });
    let constrained = !fresh || headroom < reserve + 15.0 || pace_tight;
    d.constrained = constrained;
    let (mut desired, mut effort) = match kind.as_str() {
        "foundation" => (3, "high"),
        "backend" => {
            if project.large() {
                (2, "high")
            } else {
                (1, "medium")
            }
        }
        "interface" => (2, "medium"),
        _ => (1, "low"),
    };
    d.reasons.push(format!(
        "{} · {} source files{}",
        kind,
        project.source_files,
        if project.early_project {
            " · early project"
        } else {
            ""
        }
    ));
    if !fresh {
        desired = 1;
        effort = "low";
        d.reasons.push(
            "Usage is unknown, stale, or awaiting reset confirmation; use a conservative choice."
                .into(),
        );
    } else if headroom <= reserve {
        desired = 0;
        effort = "low";
        d.reasons
            .push(format!("Conserve usage below {reserve:.0}% remaining."));
    } else if constrained {
        desired = desired.min(if kind == "foundation" { 2 } else { 1 });
        effort = "medium";
        d.reasons.push(
            if pace_tight {
                "Conserve usage until the reset."
            } else {
                "Shared usage is running low."
            }
            .into(),
        );
    }
    let eligible: Vec<_> = models
        .into_iter()
        .filter(|m| {
            let specific: Vec<_> = state
                .windows
                .iter()
                .filter(|w| {
                    !w.model_ids.is_empty()
                        && (w.model_ids.contains(&m.id) || m.quota_ids.contains(&w.id))
                })
                .collect();
            if specific
                .iter()
                .any(|w| !w.fresh(at) || w.used_percent >= 100.0)
            {
                return false;
            }
            if m.requires_special_allowance {
                let special: Vec<_> = specific.iter().filter(|w| w.special_allowance).collect();
                if !preferences.use_fable_allowance
                    || !state.subscription
                    || !fresh
                    || constrained
                    || special.is_empty()
                    || !shared.iter().any(|w| {
                        w.duration_minutes.is_some_and(|m| m >= 10080.0) || w.id == "seven_day"
                    })
                    || special.iter().any(|w| w.remaining() <= reserve + 10.0)
                {
                    return false;
                }
            }
            true
        })
        .collect();
    if eligible.is_empty() {
        d.blocked = true;
        d.reasons
            .push("No included model has confirmed available usage.".into());
        return d;
    }
    let expiring = fresh
        && !constrained
        && preferences.use_expiring_headroom
        && kind != "smallTask"
        && shared.iter().all(|w| w.remaining() >= reserve + 20.0)
        && shared.iter().any(|w| {
            w.duration_minutes.is_some_and(|mins| {
                mins > 0.0
                    && w.remaining() >= 60.0
                    && w.resets_at - at <= 3600.0_f64.min(mins * 6.0)
            })
        });
    if expiring {
        desired = (desired + 1).min(3);
        effort = "high";
        d.boosted = true;
        d.reasons
            .push("A reset is near with substantial headroom in the other shared windows.".into());
    }
    let mut below: Vec<_> = eligible
        .iter()
        .copied()
        .filter(|m| m.role <= desired)
        .collect();
    let selected = if below.is_empty() {
        *eligible.iter().min_by_key(|m| (m.role, &m.id)).unwrap()
    } else {
        below.sort_by(|a, b| b.role.cmp(&a.role).then(a.id.cmp(&b.id)));
        below[0]
    };
    if selected.requires_special_allowance {
        d.reasons
            .push("Both the shared and separate Fable allowances have confirmed headroom.".into());
    }
    if kind == "foundation"
        && project.early_project
        && project.large()
        && !constrained
        && preferences.allow_foundation_max
        && !d.boosted
        && headroom >= 75.0
    {
        effort = "max";
    }
    let rank = effort_rank(effort).unwrap();
    let Some(actual) = selected
        .efforts
        .iter()
        .filter(|e| effort_rank(e).is_some_and(|r| r <= rank))
        .max_by_key(|e| effort_rank(e).unwrap())
    else {
        d.blocked = true;
        d.reasons
            .push("No suitable advertised effort is available. Refresh the model catalog.".into());
        return d;
    };
    d.model = Some(selected.clone());
    d.effort = Some(actual.clone());
    d
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (Assessment, State, Preferences) {
        let p = Assessment {
            source_files: 400,
            backend_files: 200,
            manifests: 5,
            early_project: true,
            ..Default::default()
        };
        let models = ["economy", "everyday", "strong", "frontier"]
            .iter()
            .enumerate()
            .map(|(i, id)| Model {
                id: id.to_string(),
                name: id.to_string(),
                role: i as u8,
                efforts: ["low", "medium", "high", "max"]
                    .iter()
                    .map(|x| x.to_string())
                    .collect(),
                included: true,
                ..Default::default()
            })
            .collect();
        let s = State {
            provider: "codex".into(),
            models,
            windows: vec![Window {
                id: "weekly".into(),
                used_percent: 10.0,
                resets_at: 1_800_086_400.0,
                duration_minutes: Some(10080.0),
                observed_at: 1_800_000_000.0,
                ..Default::default()
            }],
            subscription: true,
            ..Default::default()
        };
        (
            p,
            s,
            Preferences {
                enabled: true,
                reserve_percent: 20.0,
                use_expiring_headroom: true,
                ..Default::default()
            },
        )
    }
    #[test]
    fn different_work_changes_models_between_turns() {
        let (p, s, config) = fixture();
        let backend = decide(&p, &s, &config, "foundation", 1_800_000_000.0);
        let ui = decide(&p, &s, &config, "interface", 1_800_000_000.0);
        assert_eq!(backend.model.unwrap().id, "frontier");
        assert_eq!(backend.effort.as_deref(), Some("high"));
        assert_eq!(ui.model.unwrap().id, "strong");
        assert_eq!(ui.effort.as_deref(), Some("medium"));
    }
    #[test]
    fn weekly_budget_prevents_short_window_boost() {
        let (p, mut s, config) = fixture();
        s.windows[0].used_percent = 90.0;
        s.windows.push(Window {
            id: "short".into(),
            used_percent: 5.0,
            resets_at: 1_800_000_060.0,
            duration_minutes: Some(300.0),
            observed_at: 1_800_000_000.0,
            ..Default::default()
        });
        let d = decide(&p, &s, &config, "interface", 1_800_000_000.0);
        assert!(!d.boosted);
        assert_eq!(d.model.unwrap().id, "economy");
    }
    #[test]
    fn stale_snapshot_is_not_a_reset() {
        let (p, mut s, config) = fixture();
        s.windows[0].resets_at = 1_799_999_999.0;
        let d = decide(&p, &s, &config, "foundation", 1_800_000_000.0);
        assert!(d.constrained);
        assert_eq!(d.effort.as_deref(), Some("low"));
    }
    #[test]
    fn exhausted_fable_falls_back_but_shared_exhaustion_blocks() {
        let (p, mut s, mut config) = fixture();
        config.use_fable_allowance = true;
        s.models[3].requires_special_allowance = true;
        s.windows.push(Window {
            id: "fable".into(),
            used_percent: 100.0,
            resets_at: 1_800_086_400.0,
            model_ids: vec!["frontier".into()],
            special_allowance: true,
            observed_at: 1_800_000_000.0,
            ..Default::default()
        });
        assert_eq!(
            decide(&p, &s, &config, "foundation", 1_800_000_000.0)
                .model
                .unwrap()
                .id,
            "strong"
        );
        s.windows[0].used_percent = 100.0;
        assert!(decide(&p, &s, &config, "foundation", 1_800_000_000.0).blocked);
    }
    #[test]
    fn task_hints_and_unsupported_efforts_are_bounded() {
        assert_eq!(
            prompt_kind("Now polish the UI layout", "backend"),
            "interface"
        );
        assert_eq!(
            prompt_kind("Design the database schema", "interface"),
            "foundation"
        );
        assert!(
            !Model {
                id: "x;rm -rf /".into(),
                efforts: vec!["high".into()],
                ..Default::default()
            }
            .valid()
        );
        let (p, mut s, config) = fixture();
        for m in &mut s.models {
            m.efforts = vec!["max".into()]
        }
        assert!(
            decide(&p, &s, &config, "interface", 1_800_000_000.0)
                .model
                .is_none()
        );
    }
}
