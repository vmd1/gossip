//! Battery level sync: the `battery.state` slot (`{"level": 0-100, "isCharging": bool}`; see `crate::state_sync`).
//!
//! A device publishes its reading whenever it changes and the core keeps every other device's copy correct, so nothing
//! here resends. Receiving is last-write-wins per sender and idempotent. The low-battery alert fires once per low *episode*: it
//! re-arms after the device charges or climbs above `REARM_LEVEL`, so a resent report can never alert twice.

use std::collections::{HashMap, HashSet};

use serde_json::{Map, Value};

use super::object;

/// The state slot a device publishes its battery in.
pub const SLOT: &str = "battery.state";

pub const LOW_THRESHOLD: u8 = 20;
pub const REARM_LEVEL: u8 = 30;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BatteryState {
    pub level: u8,
    pub is_charging: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Effect {
    /// Publish this device's reading: set the `battery.state` slot to [`Battery::payload`].
    SetState(BatteryState),
    /// Raise a low-battery notification for `sender`.
    LowBattery { sender: String, level: u8 },
    /// `sender`'s stored state changed (refresh the UI).
    Updated { sender: String },
}

#[derive(Debug, Clone, Default)]
pub struct Battery {
    last_reported: Option<BatteryState>,
    by_sender: HashMap<String, BatteryState>,
    alerted: HashSet<String>,
}

impl Battery {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn state_of(&self, sender: &str) -> Option<BatteryState> {
        self.by_sender.get(sender).copied()
    }

    pub fn payload(state: BatteryState) -> Map<String, Value> {
        object([
            ("level", u64::from(state.level).into()),
            ("isCharging", state.is_charging.into()),
        ])
    }

    /// A local power-source reading: publishes only if it differs from the last one published (so it is safe to call on
    /// every power event or on a timer). `None` (no battery, or unreadable) publishes nothing.
    pub fn report(&mut self, reading: Option<BatteryState>) -> Option<Effect> {
        let now = reading?;
        if self.last_reported == Some(now) {
            return None;
        }
        self.last_reported = Some(now);
        Some(Effect::SetState(now))
    }

    /// A device was revoked: forget its reading and its alert state.
    pub fn forget(&mut self, sender: &str) {
        self.by_sender.remove(sender);
        self.alerted.remove(sender);
    }

    pub fn on_update(&mut self, sender: &str, payload: &Map<String, Value>) -> Vec<Effect> {
        let Some(level) = payload.get("level").and_then(Value::as_f64) else {
            return Vec::new();
        };
        let Some(is_charging) = payload.get("isCharging").and_then(Value::as_bool) else {
            return Vec::new();
        };
        let level = level.clamp(0.0, 100.0) as u8;
        let state = BatteryState { level, is_charging };
        let mut out = Vec::new();
        if self.by_sender.insert(sender.to_owned(), state) != Some(state) {
            out.push(Effect::Updated {
                sender: sender.to_owned(),
            });
        }
        if is_charging || level > REARM_LEVEL {
            self.alerted.remove(sender);
        } else if level <= LOW_THRESHOLD && self.alerted.insert(sender.to_owned()) {
            out.push(Effect::LowBattery {
                sender: sender.to_owned(),
                level,
            });
        }
        out
    }
}
