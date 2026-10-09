//! Do Not Disturb / Focus sync (`dnd.update`, `dnd.set`).
//!
//! Three rules keep two devices from fighting each other:
//! - **Echo suppression.** `expected` is the state this device believes it is in (what it last reported or applied).
//!   A peer `dnd.update` that agrees with it is ignored, and a local change report that agrees with it is not resent.
//! - **Cooldown.** Applying a peer's state changes the OS setting, which fires the local "Focus changed" trigger for
//!   the very change just made; reports inside `RECONCILE_COOLDOWN_MS` of an apply are swallowed.
//! - **OR-merge on initial sync.** Two devices that were apart can each hold a different state with neither wrong.
//!   Blindly mirroring would let concurrent reports swap states, so an `isInitialSync` report is OR-ed with the
//!   local state: DND ends up on if either side had it on, order-independently, on both sides.
//!
//! `dnd.update` is reconciled: the shell reports initial sync on every fresh connect and every 60 seconds.

use serde_json::{Map, Value};

use super::{object, Outgoing};

pub const RECONCILE_COOLDOWN_MS: i64 = 3_000;

#[derive(Debug, Clone, PartialEq)]
pub enum Effect {
    /// Send this message to the mesh.
    Send(Outgoing),
    /// Change the OS Do Not Disturb setting.
    ApplyLocal { enabled: bool },
    /// The believed state changed: persist it (the OS offers no way to read it back).
    Persist(Option<bool>),
}

#[derive(Debug, Clone, Default)]
pub struct Dnd {
    expected: Option<bool>,
    last_applied_ms: Option<i64>,
}

impl Dnd {
    pub fn new(persisted_expected: Option<bool>) -> Self {
        Self {
            expected: persisted_expected,
            last_applied_ms: None,
        }
    }

    pub fn expected(&self) -> Option<bool> {
        self.expected
    }

    pub fn update_payload(
        source_device_id: &str,
        enabled: bool,
        is_initial_sync: bool,
    ) -> Map<String, Value> {
        object([
            ("sourceDeviceId", source_device_id.into()),
            ("enabled", enabled.into()),
            ("isInitialSync", is_initial_sync.into()),
        ])
    }

    /// The local DND/Focus state changed (as observed by the OS hook).
    pub fn local_changed(
        &mut self,
        source_device_id: &str,
        enabled: bool,
        now_ms: i64,
    ) -> Vec<Effect> {
        if self
            .last_applied_ms
            .is_some_and(|t| now_ms - t < RECONCILE_COOLDOWN_MS)
            || Some(enabled) == self.expected
        {
            return Vec::new();
        }
        self.expected = Some(enabled);
        vec![
            Effect::Persist(self.expected),
            self.report(source_device_id, enabled, false),
        ]
    }

    /// Always reports the best-known state with `isInitialSync`. Call on every fresh connect and on the 60s
    /// resync. "Assume off if never observed" is the best answer when the OS cannot be read.
    pub fn initial_sync(&mut self, source_device_id: &str) -> Vec<Effect> {
        let enabled = self.expected.unwrap_or(false);
        let changed = self.expected != Some(enabled);
        self.expected = Some(enabled);
        let mut out = Vec::new();
        if changed {
            out.push(Effect::Persist(self.expected));
        }
        out.push(self.report(source_device_id, enabled, true));
        out
    }

    /// `dnd.set`: an explicit request to change this device.
    pub fn on_set(&mut self, payload: &Map<String, Value>, now_ms: i64) -> Vec<Effect> {
        match payload.get("enabled").and_then(Value::as_bool) {
            Some(enabled) => self.apply_peer_state(enabled, now_ms),
            None => Vec::new(),
        }
    }

    /// `dnd.update` from a peer.
    pub fn on_update(&mut self, payload: &Map<String, Value>, now_ms: i64) -> Vec<Effect> {
        let Some(enabled) = payload.get("enabled").and_then(Value::as_bool) else {
            return Vec::new();
        };
        if payload.get("isInitialSync").and_then(Value::as_bool) == Some(true) {
            return self.merge_initial_sync(enabled, now_ms);
        }
        if Some(enabled) == self.expected {
            return Vec::new();
        }
        self.apply_peer_state(enabled, now_ms)
    }

    fn merge_initial_sync(&mut self, remote: bool, now_ms: i64) -> Vec<Effect> {
        let local = self.expected.unwrap_or(false);
        let target = local || remote;
        if target != local {
            self.apply_peer_state(target, now_ms)
        } else if self.expected != Some(target) {
            self.expected = Some(target);
            vec![Effect::Persist(self.expected)]
        } else {
            Vec::new()
        }
    }

    fn apply_peer_state(&mut self, enabled: bool, now_ms: i64) -> Vec<Effect> {
        self.expected = Some(enabled);
        self.last_applied_ms = Some(now_ms);
        vec![
            Effect::Persist(self.expected),
            Effect::ApplyLocal { enabled },
        ]
    }

    fn report(&self, source_device_id: &str, enabled: bool, initial: bool) -> Effect {
        Effect::Send(Outgoing::broadcast(
            "dnd.update",
            Self::update_payload(source_device_id, enabled, initial),
        ))
    }
}
