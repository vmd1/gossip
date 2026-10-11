//! The mesh topic: the shared `(topicSecret, epoch)` that names this mesh's rendezvous on the relay
//! (`mesh.topic`, `docs/plans/relay.md`). Pure data and ordering rules; the engine decides when to send and apply.
//!
//! Convergence rule: the highest `epoch` wins; on an equal epoch the larger `SHA-256(topicSecret)` wins. Every
//! device applies the same total order, so they settle on one topic without flapping, and re-applying a message
//! that is not strictly newer changes nothing.

use std::cmp::Ordering;
use std::fmt;

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use zeroize::{Zeroize, ZeroizeOnDrop};

use crate::relay::TopicKeys;

/// The largest epoch a message may carry (the largest integer JSON represents exactly everywhere).
pub const MAX_EPOCH: u64 = (1 << 53) - 1;

/// 32 secret bytes that never appear in `Debug` output and are wiped on drop.
#[derive(Clone, PartialEq, Eq, Zeroize, ZeroizeOnDrop)]
pub struct TopicSecret([u8; 32]);

impl TopicSecret {
    pub fn new(bytes: [u8; 32]) -> Self {
        Self(bytes)
    }

    /// For persistence and the wire; callers must not log it.
    pub fn expose(&self) -> &[u8; 32] {
        &self.0
    }
}

impl fmt::Debug for TopicSecret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("TopicSecret(<redacted>)")
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct Topic {
    pub secret: TopicSecret,
    pub epoch: u64,
}

impl fmt::Debug for Topic {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Topic")
            .field("epoch", &self.epoch)
            .field("secret", &"<redacted>")
            .finish()
    }
}

impl Topic {
    pub fn new(secret: [u8; 32], epoch: u64) -> Self {
        Self {
            secret: TopicSecret::new(secret),
            epoch: epoch.clamp(1, MAX_EPOCH),
        }
    }

    pub fn keys(&self) -> TopicKeys {
        TopicKeys::derive(self.secret.expose(), self.epoch)
    }

    fn secret_hash(&self) -> [u8; 32] {
        Sha256::digest(self.secret.expose()).into()
    }

    /// Total order: epoch first, then the secret's hash.
    pub fn rank_cmp(&self, other: &Topic) -> Ordering {
        self.epoch
            .cmp(&other.epoch)
            .then_with(|| self.secret_hash().cmp(&other.secret_hash()))
    }

    /// The `mesh.topic` payload.
    pub fn payload(&self) -> Map<String, Value> {
        let mut m = Map::new();
        m.insert(
            "topicSecret".into(),
            Value::String(B64.encode(self.secret.expose())),
        );
        m.insert("epoch".into(), Value::from(self.epoch));
        m
    }

    /// Strictly validated: a 32-byte base64 secret and an integer epoch in `1..=MAX_EPOCH`.
    pub fn from_payload(payload: &Map<String, Value>) -> Option<Topic> {
        let secret = B64
            .decode(payload.get("topicSecret")?.as_str()?)
            .ok()?
            .try_into()
            .ok()?;
        let epoch = payload.get("epoch")?.as_u64()?;
        if epoch == 0 || epoch > MAX_EPOCH {
            return None;
        }
        Some(Topic::new(secret, epoch))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn higher_epoch_wins_then_larger_secret_hash() {
        let a = Topic::new([1; 32], 1);
        let b = Topic::new([2; 32], 2);
        assert_eq!(a.rank_cmp(&b), Ordering::Less);
        let c = Topic::new([3; 32], 1);
        assert_ne!(a.rank_cmp(&c), Ordering::Equal);
        assert_eq!(a.rank_cmp(&c), c.rank_cmp(&a).reverse());
        assert_eq!(a.rank_cmp(&a.clone()), Ordering::Equal);
    }

    #[test]
    fn payload_roundtrips_and_rejects_bad_input() {
        let t = Topic::new([7; 32], 5);
        assert_eq!(Topic::from_payload(&t.payload()), Some(t.clone()));
        let bad = [
            json!({"topicSecret": B64.encode([0u8; 31]), "epoch": 1}),
            json!({"topicSecret": B64.encode([0u8; 32]), "epoch": 0}),
            json!({"topicSecret": B64.encode([0u8; 32]), "epoch": -1}),
            json!({"topicSecret": B64.encode([0u8; 32]), "epoch": 1.5}),
            json!({"topicSecret": B64.encode([0u8; 32]), "epoch": MAX_EPOCH + 1}),
            json!({"topicSecret": "!!!", "epoch": 1}),
            json!({"epoch": 1}),
        ];
        for b in bad {
            let Value::Object(m) = b else { unreachable!() };
            assert_eq!(Topic::from_payload(&m), None, "{m:?}");
        }
    }

    #[test]
    fn debug_never_shows_the_secret() {
        let t = Topic::new([0xab; 32], 3);
        let s = format!("{t:?} {:?} {:?}", t.secret, t.keys());
        assert!(!s.contains("171") && !s.contains("ab"), "{s}");
        assert!(s.contains("redacted"));
    }
}
