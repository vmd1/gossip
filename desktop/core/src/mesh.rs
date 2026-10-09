//! The mesh forwarding rules: de-duplication, deliver-vs-forward, and hop budgets.
//!
//! A flood-forward with a hop budget, not a routing table (`docs/wire-protocol.md`, "Multi-hop relay"). Every
//! device runs the same decision on each envelope it receives; forwarding re-encrypts under each next hop's own
//! Noise session, which is the engine's job, not this module's.

use std::collections::{HashSet, VecDeque};

use crate::wire::envelope::{Envelope, DEFAULT_TTL};

/// Large enough that flushing it with unique ids (to get an old broadcast re-delivered) takes real effort.
pub const SEEN_CACHE_CAPACITY: usize = 4096;

/// Bounded cache of recently seen envelope ids, oldest evicted first.
#[derive(Debug, Clone)]
pub struct SeenCache {
    order: VecDeque<String>,
    set: HashSet<String>,
    capacity: usize,
}

impl Default for SeenCache {
    fn default() -> Self {
        Self::new(SEEN_CACHE_CAPACITY)
    }
}

impl SeenCache {
    pub fn new(capacity: usize) -> Self {
        Self {
            order: VecDeque::new(),
            set: HashSet::new(),
            capacity: capacity.max(1),
        }
    }

    /// Records `id`. `true` if this is the first time it was seen (process it), `false` for a duplicate.
    pub fn record(&mut self, id: &str) -> bool {
        if self.set.contains(id) {
            return false;
        }
        self.set.insert(id.to_owned());
        self.order.push_back(id.to_owned());
        if self.order.len() > self.capacity {
            if let Some(evicted) = self.order.pop_front() {
                self.set.remove(&evicted);
            }
        }
        true
    }

    pub fn contains(&self, id: &str) -> bool {
        self.set.contains(id)
    }

    pub fn len(&self) -> usize {
        self.order.len()
    }

    pub fn is_empty(&self) -> bool {
        self.order.is_empty()
    }
}

/// The ttl a receiver works with: `ttl` is the one field a relay can change, so a peer cannot be trusted to keep
/// it inside the mesh's budget.
pub fn clamp_ttl(ttl: i64) -> i64 {
    ttl.min(DEFAULT_TTL)
}

/// Whether `envelope` is addressed to this device (directly or by broadcast).
pub fn is_for_me(envelope: &Envelope, my_id: &str) -> bool {
    envelope.broadcast || envelope.recipient_id.as_deref() == Some(my_id)
}

/// Which directly-connected peers an envelope should be sent or forwarded to. `arrived_from` is the peer it was
/// just relayed from (never sent back to it); pass `None` for a locally originated send.
///
/// - Broadcast: every peer except where it came from.
/// - Directed at someone else: that peer if it is directly connected, otherwise (unless `ttl` is 0, which makes
///   an envelope direct-only so key material is never flooded to bystanders) every peer except where it came from.
pub fn forward_targets<'a>(
    envelope: &Envelope,
    arrived_from: Option<&str>,
    my_id: &str,
    peers: impl IntoIterator<Item = &'a str>,
) -> Vec<String> {
    let peers: Vec<&str> = peers.into_iter().collect();
    let others = || {
        peers
            .iter()
            .filter(|p| Some(**p) != arrived_from)
            .map(|p| (*p).to_owned())
            .collect::<Vec<_>>()
    };
    if envelope.broadcast {
        return others();
    }
    let Some(recipient) = envelope.recipient_id.as_deref().filter(|r| *r != my_id) else {
        return Vec::new();
    };
    if peers.contains(&recipient) {
        return vec![recipient.to_owned()];
    }
    if envelope.ttl <= 0 {
        return Vec::new();
    }
    others()
}

/// What to do with a received envelope that already passed validation and de-duplication.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Routing {
    pub deliver: bool,
    pub forward_to: Vec<String>,
    /// The ttl to put on each forwarded copy.
    pub forward_ttl: i64,
}

pub fn route_received<'a>(
    envelope: &Envelope,
    arrived_from: &str,
    my_id: &str,
    peers: impl IntoIterator<Item = &'a str>,
) -> Routing {
    let forward_to = if envelope.ttl > 0 {
        forward_targets(envelope, Some(arrived_from), my_id, peers)
    } else {
        Vec::new()
    };
    Routing {
        deliver: is_for_me(envelope, my_id),
        forward_to,
        forward_ttl: envelope.ttl - 1,
    }
}
