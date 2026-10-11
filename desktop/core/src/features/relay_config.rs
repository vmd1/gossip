//! Relay settings shared across the mesh: configure the relay (on/off, custom address) on one device and every paired
//! device follows.
//!
//! Each device publishes its relay choice in the `relay.config` state slot (see `crate::state_sync`), which the core
//! already reconciles. The choice carries `changedAt`, the wall-clock time of the user's last edit, and the newest edit
//! wins (ties broken by content so every device converges on the same value). Adopting a peer's choice keeps *its*
//! `changedAt`, so applying the same slot twice, or a peer echoing it back, changes nothing. A device whose settings were
//! never edited has `changedAt == 0` and publishes nothing, so it can never override a configured peer.

use serde_json::{Map, Value};

use super::object;

/// The state slot every device publishes its relay choice in. Not tied to a feature toggle.
pub const SLOT: &str = "relay.config";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RelayConfig {
    pub enabled: bool,
    /// A normalized custom origin, or `None` to use the directory's relay.
    pub custom_url: Option<String>,
    /// Milliseconds since the epoch of the user's last edit; 0 when never edited.
    pub changed_at: i64,
}

impl RelayConfig {
    /// A device's initial state: never edited.
    pub fn unset() -> Self {
        Self {
            enabled: false,
            custom_url: None,
            changed_at: 0,
        }
    }

    pub fn payload(&self) -> Map<String, Value> {
        object([
            ("enabled", Value::Bool(self.enabled)),
            (
                "customUrl",
                self.custom_url.clone().map_or(Value::Null, Value::String),
            ),
            ("changedAt", Value::from(self.changed_at)),
        ])
    }

    pub fn parse(payload: &Map<String, Value>) -> Option<Self> {
        let changed_at = payload.get("changedAt")?.as_i64().filter(|t| *t > 0)?;
        let custom_url = match payload.get("customUrl") {
            None | Some(Value::Null) => None,
            Some(Value::String(s)) if s.is_empty() => None,
            Some(Value::String(s)) if s.len() <= 512 => Some(s.clone()),
            _ => return None,
        };
        Some(Self {
            enabled: payload.get("enabled")?.as_bool()?,
            custom_url,
            changed_at,
        })
    }

    /// Whether `self` should replace `current`: it is newer, or equally new with a greater content key. A config that
    /// was never edited (`changed_at == 0`) supersedes nothing.
    pub fn supersedes(&self, current: &Self) -> bool {
        if self.changed_at <= 0 {
            return false;
        }
        if self.changed_at != current.changed_at {
            return self.changed_at > current.changed_at;
        }
        (self.enabled, &self.custom_url) > (current.enabled, &current.custom_url)
    }
}

/// The `changedAt` for a local edit made at `now_ms`: never behind what this device has already seen, so an edit made
/// after adopting a peer's newer-clocked change still wins.
pub fn next_changed_at(now_ms: i64, current: i64) -> i64 {
    now_ms.max(current + 1).max(1)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg(enabled: bool, url: Option<&str>, at: i64) -> RelayConfig {
        RelayConfig {
            enabled,
            custom_url: url.map(str::to_owned),
            changed_at: at,
        }
    }

    #[test]
    fn newest_edit_wins_and_adopting_is_idempotent() {
        let mine = cfg(false, None, 100);
        let theirs = cfg(true, Some("wss://relay.example.com"), 200);
        assert!(theirs.supersedes(&mine));
        assert!(!mine.supersedes(&theirs));
        assert!(!theirs.supersedes(&theirs), "re-applying the same config is a no-op");
    }

    #[test]
    fn ties_converge_on_one_value() {
        let a = cfg(true, None, 5);
        let b = cfg(false, Some("wss://x.example.com"), 5);
        assert_ne!(a.supersedes(&b), b.supersedes(&a));
    }

    #[test]
    fn an_unedited_device_never_overrides_and_adopts_anything() {
        let unset = RelayConfig::unset();
        assert!(!unset.supersedes(&cfg(true, None, 1)));
        assert!(cfg(false, None, 1).supersedes(&unset));
    }

    #[test]
    fn payload_round_trips_and_rejects_junk() {
        let c = cfg(true, Some("wss://relay.example.com"), 42);
        assert_eq!(RelayConfig::parse(&c.payload()), Some(c));
        assert_eq!(RelayConfig::parse(&RelayConfig::unset().payload()), None);
        let mut bad = cfg(true, None, 1).payload();
        bad.insert("customUrl".into(), Value::from(5));
        assert_eq!(RelayConfig::parse(&bad), None);
    }

    #[test]
    fn a_local_edit_is_never_behind_the_current_value() {
        assert_eq!(next_changed_at(100, 50), 100);
        assert_eq!(next_changed_at(100, 500), 501);
        assert_eq!(next_changed_at(0, 0), 1);
    }
}
