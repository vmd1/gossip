//! Who a peer says it is: the identity JSON carried inside the (encrypted) Noise handshake payloads, and the
//! plaintext `handshake.hello` / `handshake.ack` envelopes that carry the Noise messages themselves.

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use thiserror::Error;

use super::envelope::Envelope;
use super::uuid;

pub const HELLO: &str = "handshake.hello";
pub const ACK: &str = "handshake.ack";
pub const MAX_DEVICE_NAME_CHARS: usize = 80;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum HandshakeError {
    #[error("handshake identity is malformed")]
    BadIdentity,
    #[error("not a handshake envelope of the expected type")]
    WrongEnvelope,
}

/// What a device is. Unknown strings are kept, not rejected, so new device types never break an older peer.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum DeviceType {
    Mac,
    AndroidPhone,
    AndroidTablet,
    Windows,
    Linux,
    Other(String),
}

impl DeviceType {
    pub fn parse(s: &str) -> Self {
        match s {
            "mac" => Self::Mac,
            "android-phone" => Self::AndroidPhone,
            "android-tablet" => Self::AndroidTablet,
            "windows" => Self::Windows,
            "linux" => Self::Linux,
            other => Self::Other(other.to_owned()),
        }
    }

    pub fn as_str(&self) -> &str {
        match self {
            Self::Mac => "mac",
            Self::AndroidPhone => "android-phone",
            Self::AndroidTablet => "android-tablet",
            Self::Windows => "windows",
            Self::Linux => "linux",
            Self::Other(s) => s,
        }
    }
}

/// The identity payload of Noise message 1 (initiator) and message 2 (responder, without `pairingToken`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HandshakeIdentity {
    #[serde(rename = "deviceId")]
    pub device_id: String,
    #[serde(rename = "deviceName")]
    pub device_name: String,
    #[serde(rename = "deviceType")]
    pub device_type: String,
    /// Base64 raw Ed25519 public key.
    #[serde(rename = "signingPublicKey")]
    pub signing_public_key: String,
    /// Only sent by a device that scanned a pairing QR; proves it saw that code.
    #[serde(
        rename = "pairingToken",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub pairing_token: Option<String>,
}

impl HandshakeIdentity {
    pub fn encode(&self) -> Vec<u8> {
        serde_json::to_vec(self).expect("an identity always serialises")
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, HandshakeError> {
        let id: Self = serde_json::from_slice(bytes).map_err(|_| HandshakeError::BadIdentity)?;
        let key_ok = B64
            .decode(&id.signing_public_key)
            .map(|k| k.len() == 32)
            .unwrap_or(false);
        if !uuid::is_valid(&id.device_id) || !key_ok {
            return Err(HandshakeError::BadIdentity);
        }
        Ok(id)
    }

    pub fn signing_key_bytes(&self) -> [u8; 32] {
        B64.decode(&self.signing_public_key)
            .ok()
            .and_then(|k| k.try_into().ok())
            .unwrap_or([0; 32])
    }

    pub fn device_type(&self) -> DeviceType {
        DeviceType::parse(&self.device_type)
    }

    /// The device name as it may be displayed and stored (first 80 characters).
    pub fn display_name(&self) -> String {
        self.device_name
            .chars()
            .take(MAX_DEVICE_NAME_CHARS)
            .collect()
    }
}

/// Wraps a Noise handshake message in its plaintext envelope (`noise` = base64 of the message).
pub fn handshake_envelope(
    kind: &str,
    id: String,
    sender_id: &str,
    recipient_id: Option<&str>,
    ts: i64,
    noise: &[u8],
) -> Envelope {
    let mut payload = Map::new();
    payload.insert("noise".to_owned(), Value::String(B64.encode(noise)));
    let mut e = Envelope::new(id, kind, sender_id, ts).with_payload(payload);
    e.recipient_id = recipient_id.map(str::to_owned);
    e
}

/// Extracts the Noise message bytes from a handshake envelope of type `expected`.
pub fn noise_bytes(envelope: &Envelope, expected: &str) -> Result<Vec<u8>, HandshakeError> {
    if envelope.kind != expected {
        return Err(HandshakeError::WrongEnvelope);
    }
    match envelope.payload.get("noise") {
        Some(Value::String(s)) => B64.decode(s).map_err(|_| HandshakeError::WrongEnvelope),
        _ => Err(HandshakeError::WrongEnvelope),
    }
}
