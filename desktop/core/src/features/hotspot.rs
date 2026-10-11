//! Whether each trusted phone's Instant Hotspot is on: the `hotspot.state` slot (`{"enabled": bool, "ssid"?: string}`;
//! see `crate::state_sync`). The core keeps it correct across reconnects, so there is no resync here; this module is the
//! payload shape and the per-sender map. Last-write-wins per sender and idempotent.

use std::collections::HashMap;

use serde_json::{Map, Value};

/// The state slot a phone publishes its hotspot state in.
pub const SLOT: &str = "hotspot.state";

/// The slot value for a phone whose hotspot is `enabled` (with its `ssid` when readable).
pub fn state_payload(enabled: bool, ssid: Option<&str>) -> Map<String, Value> {
    let mut m = Map::new();
    m.insert("enabled".into(), enabled.into());
    if let (true, Some(ssid)) = (enabled, ssid) {
        m.insert("ssid".into(), ssid.into());
    }
    m
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HotspotState {
    pub enabled: bool,
    /// Best effort: only present when the reporting phone could read it.
    pub ssid: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct HotspotStates {
    by_sender: HashMap<String, HotspotState>,
}

impl HotspotStates {
    pub fn new() -> Self {
        Self::default()
    }

    /// Returns whether the stored state changed.
    pub fn on_update(&mut self, sender: &str, payload: &Map<String, Value>) -> bool {
        let Some(enabled) = payload.get("enabled").and_then(Value::as_bool) else {
            return false;
        };
        let state = HotspotState {
            enabled,
            ssid: payload
                .get("ssid")
                .and_then(Value::as_str)
                .map(str::to_owned),
        };
        self.by_sender.insert(sender.to_owned(), state.clone()) != Some(state)
    }

    /// A device was revoked, or its slot was cleared.
    pub fn forget(&mut self, sender: &str) {
        self.by_sender.remove(sender);
    }

    pub fn state_of(&self, sender: &str) -> Option<&HotspotState> {
        self.by_sender.get(sender)
    }
}
