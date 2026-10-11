//! Lock on leave: lock this computer when a trusted phone walks out of BLE range.
//!
//! The `lock_on_leave.config` slot (see `crate::state_sync`) is published by a phone and lists the computers it arms
//! (`{"armedFor": [deviceId, ...]}`); it is reconciled by the core. The trigger is local: the
//! computer is the BLE central, so it learns directly when a device leaves confirmed range. Two rules keep it from
//! being hostile: it fires once per range-loss *transition*, not on every tick while a device stays away, and a
//! per-device cooldown stops a device flapping at the RSSI threshold from re-locking a screen the user has since
//! manually unlocked.

use std::collections::{HashMap, HashSet};

use serde_json::{Map, Value};

use super::object;

pub const COOLDOWN_MS: i64 = 30_000;

/// The state slot a phone publishes its lock-on-leave arming in.
pub const SLOT: &str = "lock_on_leave.config";

/// The slot value for a phone that arms lock-on-leave for the computers in `armed_for`.
pub fn config_payload(armed_for: &[String]) -> Map<String, Value> {
    let mut sorted: Vec<&String> = armed_for.iter().collect();
    sorted.sort();
    sorted.dedup();
    object([(
        "armedFor",
        Value::Array(
            sorted
                .into_iter()
                .map(|d| Value::String(d.clone()))
                .collect(),
        ),
    )])
}

/// Whether the phone that published `payload` armed lock-on-leave for `me`.
pub fn is_armed_for(payload: &Map<String, Value>, me: &str) -> bool {
    payload
        .get("armedFor")
        .and_then(Value::as_array)
        .is_some_and(|list| list.iter().any(|v| v.as_str() == Some(me)))
}

#[derive(Debug, Clone, Default)]
pub struct LockOnLeave {
    previous_nearby: HashSet<String>,
    last_fired_ms: HashMap<String, i64>,
}

impl LockOnLeave {
    pub fn new(initially_nearby: HashSet<String>) -> Self {
        Self {
            previous_nearby: initially_nearby,
            last_fired_ms: HashMap::new(),
        }
    }

    /// The set of nearby trusted devices changed. Returns true if the screen should be locked now.
    ///
    /// `feature_enabled` is this device's own toggle (a local trigger, so the message gate cannot cover it) and
    /// `lock_enabled` says whether the device that left armed lock-on-leave for itself.
    pub fn nearby_changed(
        &mut self,
        nearby: HashSet<String>,
        now_ms: i64,
        feature_enabled: bool,
        lock_enabled: impl Fn(&str) -> bool,
    ) -> bool {
        let just_left: Vec<String> = self.previous_nearby.difference(&nearby).cloned().collect();
        self.previous_nearby = nearby;
        if !feature_enabled {
            return false;
        }
        let mut lock = false;
        for device in just_left {
            if !lock_enabled(&device) {
                continue;
            }
            if self
                .last_fired_ms
                .get(&device)
                .is_some_and(|last| now_ms - last < COOLDOWN_MS)
            {
                continue;
            }
            self.last_fired_ms.insert(device, now_ms);
            lock = true;
        }
        lock
    }
}
