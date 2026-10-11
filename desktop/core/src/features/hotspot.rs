//! The receiving half of `hotspot.state_update`: whether each trusted phone's Instant Hotspot is on, as last
//! reported over the mesh. Last-write-wins per sender and idempotent; the phone's own resync (on connect and every
//! 60s) is what makes it self-healing, so nothing here needs a resync of its own.

use std::collections::HashMap;

use serde_json::{Map, Value};

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

    pub fn state_of(&self, sender: &str) -> Option<&HotspotState> {
        self.by_sender.get(sender)
    }
}
