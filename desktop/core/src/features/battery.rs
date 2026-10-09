//! Battery level sync (`battery.update`).
//!
//! Reconciled like the other state messages: sent on every local change, on every fresh connect and every 60s.
//! Receiving is last-write-wins per sender and idempotent. The low-battery alert fires once per low *episode*: it
//! re-arms after the device charges or climbs above `REARM_LEVEL`, so a resent report can never alert twice.

use std::collections::{HashMap, HashSet};

use serde_json::{Map, Value};

use super::{object, Outgoing};

pub const LOW_THRESHOLD: u8 = 20;
pub const REARM_LEVEL: u8 = 30;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BatteryState {
    pub level: u8,
    pub is_charging: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Effect {
    Send(Outgoing),
    /// Raise a low-battery notification for `sender`.
    LowBattery {
        sender: String,
        level: u8,
    },
    /// `sender`'s stored state changed (refresh the UI).
    Updated {
        sender: String,
    },
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

    pub fn payload(source_device_id: &str, state: BatteryState) -> Map<String, Value> {
        object([
            ("sourceDeviceId", source_device_id.into()),
            ("level", u64::from(state.level).into()),
            ("isCharging", state.is_charging.into()),
        ])
    }

    /// A local power-source change: sends only if the reading differs from the last one sent.
    pub fn report_if_changed(&mut self, me: &str, reading: Option<BatteryState>) -> Option<Effect> {
        let now = reading?;
        if self.last_reported == Some(now) {
            return None;
        }
        self.last_reported = Some(now);
        Some(Effect::Send(Outgoing::broadcast(
            "battery.update",
            Self::payload(me, now),
        )))
    }

    /// Sends the current reading unconditionally: on every fresh connect and every 60s while connected.
    pub fn report_always(&mut self, me: &str, reading: Option<BatteryState>) -> Option<Effect> {
        let now = reading?;
        self.last_reported = Some(now);
        Some(Effect::Send(Outgoing::broadcast(
            "battery.update",
            Self::payload(me, now),
        )))
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
