//! Lock on leave: lock this computer when a trusted phone walks out of BLE range.
//!
//! `lock_on_leave.config` only carries the per-device on/off setting (and is reconciled). The trigger is local: the
//! computer is the BLE central, so it learns directly when a device leaves confirmed range. Two rules keep it from
//! being hostile: it fires once per range-loss *transition*, not on every tick while a device stays away, and a
//! per-device cooldown stops a device flapping at the RSSI threshold from re-locking a screen the user has since
//! manually unlocked.

use std::collections::{HashMap, HashSet};

use serde_json::{Map, Value};

use super::object;

pub const COOLDOWN_MS: i64 = 30_000;

pub fn config_payload(enabled: bool) -> Map<String, Value> {
    object([("enabled", enabled.into())])
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
