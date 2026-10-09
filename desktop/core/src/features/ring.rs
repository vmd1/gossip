//! Find my device (`device.ring`, `device.ring_state`).
//!
//! A one-shot trigger, so there is no resync loop, but it is idempotent: `start` while already ringing is a no-op,
//! `stop` while silent is a no-op, and a duplicate or late `start` (identified by its per-attempt `ringId`, kept in
//! a bounded recently-handled cache) can never restart a ring the user already stopped. Rings stop on their own
//! after `AUTO_STOP_MS`. Whenever a device starts or stops ringing it reports `device.ring_state` to whoever started
//! the ring, so that side's button can show "ringing"; that entry also expires after `PEER_EXPIRY_MS` as the
//! backstop if a report is ever lost.

use std::collections::HashMap;

use serde_json::{Map, Value};

use super::{object, Outgoing};
use crate::limits::RecentIds;

pub const AUTO_STOP_MS: i64 = 30_000;
pub const PEER_EXPIRY_MS: i64 = 35_000;
const RECENT_CACHE_SIZE: usize = 64;

#[derive(Debug, Clone, PartialEq)]
pub enum Effect {
    StartRinger,
    StopRinger,
    ShowAlert,
    CloseAlert,
    Send(Outgoing),
    /// The set of peers this device has asked to ring changed.
    PeersChanged,
}

#[derive(Debug, Clone)]
pub struct Ring {
    recent: RecentIds,
    ringing: bool,
    requester: Option<String>,
    auto_stop_at: Option<i64>,
    /// Peers this device asked to ring, with the time their entry expires.
    peers: HashMap<String, i64>,
}

impl Default for Ring {
    fn default() -> Self {
        Self {
            recent: RecentIds::new(RECENT_CACHE_SIZE),
            ringing: false,
            requester: None,
            auto_stop_at: None,
            peers: HashMap::new(),
        }
    }
}

impl Ring {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn is_ringing(&self) -> bool {
        self.ringing
    }

    pub fn ringing_peers(&self) -> Vec<String> {
        let mut v: Vec<_> = self.peers.keys().cloned().collect();
        v.sort();
        v
    }

    pub fn ring_payload(action: &str, ring_id: &str) -> Map<String, Value> {
        object([("action", action.into()), ("ringId", ring_id.into())])
    }

    /// Receiving `device.ring`.
    pub fn on_ring(
        &mut self,
        sender: &str,
        payload: &Map<String, Value>,
        now_ms: i64,
    ) -> Vec<Effect> {
        let (Some(action), Some(ring_id)) = (
            payload.get("action").and_then(Value::as_str),
            payload.get("ringId").and_then(Value::as_str),
        ) else {
            return Vec::new();
        };
        match action {
            "start" => {
                if !self.recent.first_time(ring_id) || self.ringing {
                    return Vec::new();
                }
                self.ringing = true;
                self.requester = Some(sender.to_owned());
                self.auto_stop_at = Some(now_ms + AUTO_STOP_MS);
                let mut out = vec![Effect::StartRinger];
                out.extend(self.report(true));
                out.push(Effect::ShowAlert);
                out
            }
            "stop" => self.stop_ringing(),
            _ => Vec::new(),
        }
    }

    /// Silences the ring (also the local Stop button). No-op when not ringing.
    pub fn stop_ringing(&mut self) -> Vec<Effect> {
        self.auto_stop_at = None;
        if !self.ringing {
            return Vec::new();
        }
        self.ringing = false;
        let mut out = vec![Effect::StopRinger, Effect::CloseAlert];
        out.extend(self.report(false));
        self.requester = None;
        out
    }

    fn report(&self, ringing: bool) -> Option<Effect> {
        let requester = self.requester.as_deref()?;
        Some(Effect::Send(Outgoing::to(
            "device.ring_state",
            requester,
            object([("ringing", ringing.into())]),
        )))
    }

    /// The ring button for `peer`: stops its ring if it is ringing, otherwise starts one. `ring_id` must be fresh.
    pub fn toggle(&mut self, peer: &str, ring_id: &str, now_ms: i64) -> Vec<Effect> {
        let stopping = self.peers.contains_key(peer);
        let message = Outgoing::to(
            "device.ring",
            peer,
            Self::ring_payload(if stopping { "stop" } else { "start" }, ring_id),
        );
        self.set_peer(peer, !stopping, now_ms);
        vec![Effect::Send(message), Effect::PeersChanged]
    }

    /// Receiving `device.ring_state` from a peer we asked to ring.
    pub fn on_ring_state(
        &mut self,
        sender: &str,
        payload: &Map<String, Value>,
        now_ms: i64,
    ) -> Vec<Effect> {
        match payload.get("ringing").and_then(Value::as_bool) {
            Some(ringing) => {
                self.set_peer(sender, ringing, now_ms);
                vec![Effect::PeersChanged]
            }
            None => Vec::new(),
        }
    }

    fn set_peer(&mut self, peer: &str, ringing: bool, now_ms: i64) {
        if ringing {
            self.peers.insert(peer.to_owned(), now_ms + PEER_EXPIRY_MS);
        } else {
            self.peers.remove(peer);
        }
    }

    /// Auto-stop and peer-entry expiry. Call about once a second.
    pub fn tick(&mut self, now_ms: i64) -> Vec<Effect> {
        let mut out = Vec::new();
        if self.auto_stop_at.is_some_and(|t| now_ms >= t) {
            out.extend(self.stop_ringing());
        }
        let before = self.peers.len();
        self.peers.retain(|_, expires| now_ms < *expires);
        if self.peers.len() != before {
            out.push(Effect::PeersChanged);
        }
        out
    }
}
