//! Do Not Disturb / Focus sync: the `dnd.state` slot and the explicit `dnd.set` request.
//!
//! Each device publishes its believed DND state as the `dnd.state` slot (`{"enabled": bool}`; see `crate::state_sync`),
//! and the core keeps every other device's copy correct, so there is no resync here. What stays in this module is the
//! decision logic, which has three rules that keep two devices from fighting each other:
//! - **Echo suppression.** `expected` is the state this device believes it is in (what it last reported or applied).
//!   A peer state that agrees with it is ignored, and a local change report that agrees with it is not sent again.
//! - **Cooldown.** Applying a peer's state changes the OS setting, which fires the local "Focus changed" trigger for
//!   the very change just made; reports inside `RECONCILE_COOLDOWN_MS` of an apply are swallowed.
//! - **OR-merge on first contact.** Two devices that were apart can each hold a different state with neither wrong.
//!   Blindly mirroring would let two first reports swap states, so the *first* state seen from a device is OR-ed with
//!   the local state: DND ends up on if either side had it on, order-independently, on both sides. Later changes from
//!   that device are mirrored.

use std::collections::HashSet;

use serde_json::{Map, Value};

use super::object;

/// The state slot a device publishes its DND state in.
pub const SLOT: &str = "dnd.state";
pub const RECONCILE_COOLDOWN_MS: i64 = 3_000;

#[derive(Debug, Clone, PartialEq)]
pub enum Effect {
    /// Publish this device's state: set the `dnd.state` slot to [`state_payload`]`(enabled)`.
    SetState { enabled: bool },
    /// Change the OS Do Not Disturb setting.
    ApplyLocal { enabled: bool },
    /// The believed state changed: persist it (the OS offers no way to read it back).
    Persist(Option<bool>),
}

#[derive(Debug, Clone, Default)]
pub struct Dnd {
    expected: Option<bool>,
    last_applied_ms: Option<i64>,
    /// Devices whose state has already been merged once this run.
    seen: HashSet<String>,
}

pub fn state_payload(enabled: bool) -> Map<String, Value> {
    object([("enabled", enabled.into())])
}

impl Dnd {
    pub fn new(persisted_expected: Option<bool>) -> Self {
        Self {
            expected: persisted_expected,
            last_applied_ms: None,
            seen: HashSet::new(),
        }
    }

    pub fn expected(&self) -> Option<bool> {
        self.expected
    }

    /// Call once at start: publishes the best-known state ("assume off if never observed", the best answer when the
    /// OS cannot be read). The core sends it to every device that connects later, so it is never resent.
    pub fn start(&mut self) -> Vec<Effect> {
        let enabled = self.expected.unwrap_or(false);
        let changed = self.expected != Some(enabled);
        self.expected = Some(enabled);
        let mut out = Vec::new();
        if changed {
            out.push(Effect::Persist(self.expected));
        }
        out.push(Effect::SetState { enabled });
        out
    }

    /// The local DND/Focus state changed (as observed by the OS hook).
    pub fn local_changed(&mut self, enabled: bool, now_ms: i64) -> Vec<Effect> {
        if self
            .last_applied_ms
            .is_some_and(|t| now_ms - t < RECONCILE_COOLDOWN_MS)
            || Some(enabled) == self.expected
        {
            return Vec::new();
        }
        self.expected = Some(enabled);
        vec![Effect::Persist(self.expected), Effect::SetState { enabled }]
    }

    /// `dnd.set`: an explicit request to change this device.
    pub fn on_set(&mut self, payload: &Map<String, Value>, now_ms: i64) -> Vec<Effect> {
        match payload.get("enabled").and_then(Value::as_bool) {
            Some(enabled) => self.apply_peer_state(enabled, now_ms),
            None => Vec::new(),
        }
    }

    /// The `dnd.state` slot of `sender` changed.
    pub fn on_peer_state(
        &mut self,
        sender: &str,
        payload: &Map<String, Value>,
        now_ms: i64,
    ) -> Vec<Effect> {
        let Some(enabled) = payload.get("enabled").and_then(Value::as_bool) else {
            return Vec::new();
        };
        if self.seen.insert(sender.to_owned()) {
            return self.merge_first_contact(enabled, now_ms);
        }
        if Some(enabled) == self.expected {
            return Vec::new();
        }
        self.apply_peer_state(enabled, now_ms)
    }

    /// A device was revoked: its next state counts as first contact again.
    pub fn forget_peer(&mut self, sender: &str) {
        self.seen.remove(sender);
    }

    fn merge_first_contact(&mut self, remote: bool, now_ms: i64) -> Vec<Effect> {
        let local = self.expected.unwrap_or(false);
        let target = local || remote;
        if target != local {
            self.apply_peer_state(target, now_ms)
        } else if self.expected != Some(target) {
            self.expected = Some(target);
            vec![
                Effect::Persist(self.expected),
                Effect::SetState { enabled: target },
            ]
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
            Effect::SetState { enabled },
        ]
    }
}
