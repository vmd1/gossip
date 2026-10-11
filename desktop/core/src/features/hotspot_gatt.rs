//! Wire contract of Instant Hotspot's BLE GATT control channel (`docs/ble-hotspot-protocol.md`).
//!
//! This is not the Noise mesh: it must work with a phone that has no IP connectivity at all, so requests and
//! responses are small signed JSON documents sent in 19-byte chunks over a raw GATT service. The Swift, Kotlin and
//! Rust implementations must agree byte for byte.
//!
//! - Every request and response is signed with the sender's Ed25519 key and checked against the peer's stored
//!   signing key.
//! - Credentials in a `status` response are AES-256-GCM encrypted under a key derived from the two devices' X25519
//!   identity keys: `SHA-256(DH(local, remote) || "connect-hotspot-gatt-v1")`, domain-separated so it can never
//!   collide with the Noise session key the same keypair also derives. The signature covers the *ciphertext*.
//! - The provider rejects a request whose `t` is outside the freshness window or whose nonce it has seen, and
//!   rate-limits each BLE address before doing any crypto ([`RequestGate`]).

use std::collections::{HashMap, VecDeque};

use aes_gcm::{aead::Aead, Aes256Gcm, Key, KeyInit, Nonce};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use x25519_dalek::{PublicKey, StaticSecret};

pub const SERVICE_UUID: &str = "8f9a1000-1a2b-4c3d-9e0f-1234567890ab";
pub const REQUEST_CHARACTERISTIC_UUID: &str = "8f9a1001-1a2b-4c3d-9e0f-1234567890ab";
pub const RESPONSE_CHARACTERISTIC_UUID: &str = "8f9a1002-1a2b-4c3d-9e0f-1234567890ab";

/// Payload bytes per GATT write/notify chunk: 1 flag byte + 19 = 20, which fits the default un-negotiated ATT MTU.
pub const CHUNK_PAYLOAD_SIZE: usize = 19;
/// Requests and responses are a few hundred bytes; anything larger is not a real message.
pub const MAX_MESSAGE_BYTES: usize = 4096;
pub const FLAG_LAST_CHUNK: u8 = 0x01;
/// A request whose `t` is further than this from the provider's clock is rejected.
pub const REQUEST_FRESHNESS_MS: i64 = 2 * 60 * 1000;
const KEY_LABEL: &[u8] = b"connect-hotspot-gatt-v1";

pub fn encode_chunks(message: &[u8]) -> Vec<Vec<u8>> {
    if message.is_empty() {
        return vec![vec![FLAG_LAST_CHUNK]];
    }
    let mut chunks = Vec::new();
    let mut offset = 0;
    while offset < message.len() {
        let end = (offset + CHUNK_PAYLOAD_SIZE).min(message.len());
        let mut chunk = vec![if end == message.len() {
            FLAG_LAST_CHUNK
        } else {
            0
        }];
        chunk.extend_from_slice(&message[offset..end]);
        chunks.push(chunk);
        offset = end;
    }
    chunks
}

/// Reassembles chunks delivered one at a time. Past the size cap the message is discarded, remaining chunks
/// included, instead of buffered.
#[derive(Debug, Default)]
pub struct ChunkReassembler {
    buffer: Vec<u8>,
    overflowed: bool,
}

impl ChunkReassembler {
    pub fn new() -> Self {
        Self::default()
    }

    /// The complete message once the last chunk arrives, otherwise `None`. Resets itself after a message.
    pub fn feed(&mut self, chunk: &[u8]) -> Option<Vec<u8>> {
        let (&flags, body) = chunk.split_first()?;
        let is_last = flags & FLAG_LAST_CHUNK != 0;
        if !self.overflowed && self.buffer.len() + body.len() > MAX_MESSAGE_BYTES {
            self.overflowed = true;
            self.buffer = Vec::new();
        }
        if !self.overflowed {
            self.buffer.extend_from_slice(body);
        }
        if !is_last {
            return None;
        }
        let result = (!self.overflowed).then(|| std::mem::take(&mut self.buffer));
        self.buffer = Vec::new();
        self.overflowed = false;
        result
    }
}

/// `hotspot.toggle_request`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ToggleRequest {
    /// Requester's device id.
    pub id: String,
    /// Whether to turn the hotspot on.
    pub en: bool,
    /// Single-use nonce.
    pub n: String,
    /// Requester's clock, Unix ms, signed: bounds how long a captured request stays replayable.
    pub t: i64,
    /// Base64 Ed25519 signature.
    pub s: String,
}

fn signed_request_string(id: &str, enable: bool, nonce: &str, t: i64) -> String {
    format!("hotspot.toggle_request|{id}|{enable}|{nonce}|{t}")
}

fn signed_status_string(id: &str, enabled: bool, cred: Option<&str>, nonce: &str) -> String {
    format!(
        "hotspot.status|{id}|{enabled}|{}|{nonce}",
        cred.unwrap_or("")
    )
}

fn sign(key: &SigningKey, message: &str) -> String {
    B64.encode(key.sign(message.as_bytes()).to_bytes())
}

fn verify(public_key_b64: &str, message: &str, signature_b64: &str) -> bool {
    let Ok(pk) = B64.decode(public_key_b64) else {
        return false;
    };
    let Ok(pk) = <[u8; 32]>::try_from(pk.as_slice()) else {
        return false;
    };
    let Ok(pk) = VerifyingKey::from_bytes(&pk) else {
        return false;
    };
    let Ok(sig) = B64.decode(signature_b64) else {
        return false;
    };
    let Ok(sig) = Signature::from_slice(&sig) else {
        return false;
    };
    pk.verify(message.as_bytes(), &sig).is_ok()
}

impl ToggleRequest {
    /// `nonce` must be fresh and unique (a UUID); `now_ms` is the requester's clock.
    pub fn create(
        requester_id: &str,
        enable: bool,
        nonce: &str,
        now_ms: i64,
        key: &SigningKey,
    ) -> Self {
        let s = sign(
            key,
            &signed_request_string(requester_id, enable, nonce, now_ms),
        );
        Self {
            id: requester_id.to_owned(),
            en: enable,
            n: nonce.to_owned(),
            t: now_ms,
            s,
        }
    }

    pub fn is_signature_valid(&self, signing_public_key_b64: &str) -> bool {
        verify(
            signing_public_key_b64,
            &signed_request_string(&self.id, self.en, &self.n, self.t),
            &self.s,
        )
    }

    pub fn is_fresh(&self, now_ms: i64) -> bool {
        (now_ms - self.t).abs() <= REQUEST_FRESHNESS_MS
    }

    pub fn encode(&self) -> Vec<u8> {
        serde_json::to_vec(self).expect("a request always serialises")
    }

    pub fn decode(data: &[u8]) -> Option<Self> {
        serde_json::from_slice(data).ok()
    }
}

/// `hotspot.status`. `cred`, when present, is base64(12-byte AES-GCM nonce || ciphertext+tag) of
/// `{"ssid":...,"pass":...}`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Status {
    pub id: String,
    pub ok: bool,
    pub n: String,
    pub s: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cred: Option<String>,
}

#[derive(Serialize, Deserialize)]
struct CredentialPlaintext {
    ssid: String,
    pass: String,
}

impl Status {
    /// `credentials` is `(ssid, passphrase, shared key, gcm nonce)`; the GCM nonce must be fresh random bytes.
    pub fn create(
        provider_id: &str,
        enabled: bool,
        nonce: &str,
        key: &SigningKey,
        credentials: Option<(&str, &str, &[u8; 32], [u8; 12])>,
    ) -> Self {
        let cred = credentials.and_then(|(ssid, pass, shared, gcm_nonce)| {
            encrypt_credentials(shared, ssid, pass, gcm_nonce)
        });
        let s = sign(
            key,
            &signed_status_string(provider_id, enabled, cred.as_deref(), nonce),
        );
        Self {
            id: provider_id.to_owned(),
            ok: enabled,
            n: nonce.to_owned(),
            s,
            cred,
        }
    }

    pub fn is_signature_valid(&self, signing_public_key_b64: &str) -> bool {
        verify(
            signing_public_key_b64,
            &signed_status_string(&self.id, self.ok, self.cred.as_deref(), &self.n),
            &self.s,
        )
    }

    /// Callers must check [`Status::is_signature_valid`] first; this does not.
    pub fn decrypt_credentials(&self, shared: &[u8; 32]) -> Option<(String, String)> {
        decrypt_credentials(shared, self.cred.as_deref()?)
    }

    pub fn encode(&self) -> Vec<u8> {
        serde_json::to_vec(self).expect("a status always serialises")
    }

    pub fn decode(data: &[u8]) -> Option<Self> {
        serde_json::from_slice(data).ok()
    }
}

/// `SHA-256(DH(local, remote) || "connect-hotspot-gatt-v1")`, from the devices' X25519 identity keys.
pub fn derive_shared_secret_key(
    local_x25519_secret: [u8; 32],
    remote_x25519_public: [u8; 32],
) -> Option<[u8; 32]> {
    let shared = StaticSecret::from(local_x25519_secret)
        .diffie_hellman(&PublicKey::from(remote_x25519_public));
    if !shared.was_contributory() {
        return None;
    }
    let mut h = Sha256::new();
    h.update(shared.as_bytes());
    h.update(KEY_LABEL);
    Some(h.finalize().into())
}

fn encrypt_credentials(key: &[u8; 32], ssid: &str, pass: &str, nonce: [u8; 12]) -> Option<String> {
    let plaintext = serde_json::to_vec(&CredentialPlaintext {
        ssid: ssid.to_owned(),
        pass: pass.to_owned(),
    })
    .ok()?;
    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key));
    let ct = cipher
        .encrypt(Nonce::from_slice(&nonce), plaintext.as_slice())
        .ok()?;
    let mut combined = nonce.to_vec();
    combined.extend_from_slice(&ct);
    Some(B64.encode(combined))
}

fn decrypt_credentials(key: &[u8; 32], blob: &str) -> Option<(String, String)> {
    let raw = B64.decode(blob).ok()?;
    if raw.len() < 12 + 16 {
        return None;
    }
    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key));
    let plaintext = cipher
        .decrypt(Nonce::from_slice(&raw[..12]), &raw[12..])
        .ok()?;
    let c: CredentialPlaintext = serde_json::from_slice(&plaintext).ok()?;
    Some((c.ssid, c.pass))
}

/// Admission control for the GATT channel, which any nearby BLE device can write to: a per-address rate limit
/// (checked before any crypto) and a bounded seen-nonce set (checked after the signature verifies, so garbage
/// cannot fill it) that stops a captured, still-fresh request being replayed.
#[derive(Debug)]
pub struct RequestGate {
    seen_nonces: VecDeque<String>,
    recent_by_address: HashMap<String, VecDeque<i64>>,
    max_nonces: usize,
    max_per_window: usize,
    window_ms: i64,
    max_tracked_addresses: usize,
}

impl Default for RequestGate {
    fn default() -> Self {
        Self {
            seen_nonces: VecDeque::new(),
            recent_by_address: HashMap::new(),
            max_nonces: 256,
            max_per_window: 6,
            window_ms: 60_000,
            max_tracked_addresses: 64,
        }
    }
}

impl RequestGate {
    pub fn new() -> Self {
        Self::default()
    }

    /// Whether `address` is still under its request budget; counts this attempt.
    pub fn allow_rate(&mut self, address: &str, now_ms: i64) -> bool {
        let window = self.window_ms;
        if self.recent_by_address.len() >= self.max_tracked_addresses
            && !self.recent_by_address.contains_key(address)
        {
            self.recent_by_address
                .retain(|_, q| q.back().is_some_and(|last| now_ms - last <= window));
            if self.recent_by_address.len() >= self.max_tracked_addresses {
                return false;
            }
        }
        let q = self
            .recent_by_address
            .entry(address.to_owned())
            .or_default();
        while q.front().is_some_and(|first| now_ms - first > window) {
            q.pop_front();
        }
        if q.len() >= self.max_per_window {
            return false;
        }
        q.push_back(now_ms);
        true
    }

    /// True the first time `nonce` is seen, false for a replay.
    pub fn first_use(&mut self, nonce: &str) -> bool {
        if self.seen_nonces.iter().any(|n| n == nonce) {
            return false;
        }
        self.seen_nonces.push_back(nonce.to_owned());
        while self.seen_nonces.len() > self.max_nonces {
            self.seen_nonces.pop_front();
        }
        true
    }
}
