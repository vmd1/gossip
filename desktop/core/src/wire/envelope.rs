//! The JSON envelope that wraps every message once a Noise session is up (`schema/envelope.schema.json`).

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use thiserror::Error;

/// The hop budget an originating sender uses, and the cap applied to anything received.
pub const DEFAULT_TTL: i64 = 8;
/// Envelopes whose `ts` is further than this from the local clock are dropped (replay protection).
pub const MAX_CLOCK_SKEW_MS: i64 = 15 * 60 * 1000;
/// Cap on `id`, `type`, `senderId` and `recipientId`, so the seen-id cache cannot be used to pin memory.
pub const MAX_IDENTIFIER_BYTES: usize = 64;
/// Payload field holding the base64 SHA-256 of a raw follow-up frame.
pub const RAW_HASH_FIELD: &str = "rawSha256";

#[derive(Debug, Error, PartialEq, Eq)]
pub enum EnvelopeError {
    #[error("not a valid envelope: {0}")]
    Malformed(String),
    #[error("unsupported envelope version {0}")]
    UnsupportedVersion(u32),
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Envelope {
    pub v: u32,
    pub id: String,
    #[serde(rename = "type")]
    pub kind: String,
    #[serde(rename = "senderId")]
    pub sender_id: String,
    #[serde(rename = "recipientId", default)]
    pub recipient_id: Option<String>,
    pub broadcast: bool,
    pub ttl: i64,
    #[serde(rename = "hasRawFollowup")]
    pub has_raw_followup: bool,
    pub ts: i64,
    pub payload: Map<String, Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sig: Option<String>,
}

impl Envelope {
    /// A new unsigned envelope with the default TTL and no raw follow-up.
    pub fn new(id: String, kind: &str, sender_id: &str, ts: i64) -> Self {
        Self {
            v: 1,
            id,
            kind: kind.to_owned(),
            sender_id: sender_id.to_owned(),
            recipient_id: None,
            broadcast: false,
            ttl: DEFAULT_TTL,
            has_raw_followup: false,
            ts,
            payload: Map::new(),
            sig: None,
        }
    }

    pub fn to(mut self, recipient: &str) -> Self {
        self.recipient_id = Some(recipient.to_owned());
        self
    }

    pub fn broadcast(mut self) -> Self {
        self.broadcast = true;
        self
    }

    pub fn with_payload(mut self, payload: Map<String, Value>) -> Self {
        self.payload = payload;
        self
    }

    pub fn with_ttl(mut self, ttl: i64) -> Self {
        self.ttl = ttl;
        self
    }

    pub fn encode(&self) -> Vec<u8> {
        serde_json::to_vec(self).expect("an envelope always serialises")
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, EnvelopeError> {
        let e: Envelope =
            serde_json::from_slice(bytes).map_err(|e| EnvelopeError::Malformed(e.to_string()))?;
        if e.v != 1 {
            return Err(EnvelopeError::UnsupportedVersion(e.v));
        }
        Ok(e)
    }

    /// Cheap structural checks run before anything is cached, verified or relayed.
    pub fn is_well_formed(&self, now_ms: i64) -> bool {
        self.id.len() <= MAX_IDENTIFIER_BYTES
            && self.kind.len() <= MAX_IDENTIFIER_BYTES
            && self.sender_id.len() <= MAX_IDENTIFIER_BYTES
            && self.recipient_id.as_ref().map_or(0, |r| r.len()) <= MAX_IDENTIFIER_BYTES
            && (now_ms - self.ts).abs() <= MAX_CLOCK_SKEW_MS
    }

    /// A copy with `ttl` replaced, used when relaying.
    pub fn with_forward_ttl(&self, ttl: i64) -> Self {
        let mut c = self.clone();
        c.ttl = ttl;
        c
    }

    /// Adds the SHA-256 of `raw` to the payload (before signing), so the signature commits to the raw frame.
    pub fn binding_raw_frame(mut self, raw: &[u8]) -> Self {
        self.payload.insert(
            RAW_HASH_FIELD.to_owned(),
            Value::String(raw_frame_hash(raw)),
        );
        self
    }

    /// Whether `raw` is the frame this (signed) envelope committed to.
    pub fn raw_frame_matches(&self, raw: &[u8]) -> bool {
        match self.payload.get(RAW_HASH_FIELD) {
            Some(Value::String(expected)) => *expected == raw_frame_hash(raw),
            _ => false,
        }
    }
}

pub fn raw_frame_hash(raw: &[u8]) -> String {
    B64.encode(Sha256::digest(raw))
}
