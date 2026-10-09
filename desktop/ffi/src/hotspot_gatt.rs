//! Instant Hotspot's BLE GATT control channel (`docs/ble-hotspot-protocol.md`): signed request and status
//! documents, credential encryption, chunking and the provider-side admission gate.

use std::sync::{Arc, Mutex, MutexGuard};

use ed25519_dalek::SigningKey;
use gossip_core::features::hotspot_gatt as core;

use crate::error::GossipError;

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

fn key32(bytes: &[u8], what: &str) -> Result<[u8; 32], GossipError> {
    <[u8; 32]>::try_from(bytes)
        .map_err(|_| GossipError::invalid(format!("{what} must be exactly 32 bytes")))
}

#[uniffi::export]
pub fn hotspot_service_uuid() -> String {
    core::SERVICE_UUID.to_owned()
}

#[uniffi::export]
pub fn hotspot_request_characteristic_uuid() -> String {
    core::REQUEST_CHARACTERISTIC_UUID.to_owned()
}

#[uniffi::export]
pub fn hotspot_response_characteristic_uuid() -> String {
    core::RESPONSE_CHARACTERISTIC_UUID.to_owned()
}

/// `hotspot.toggle_request`: field names are the compact wire names.
#[derive(Debug, Clone, uniffi::Record)]
pub struct HotspotToggleRequest {
    pub id: String,
    pub en: bool,
    pub n: String,
    pub t: i64,
    pub s: String,
}

impl From<core::ToggleRequest> for HotspotToggleRequest {
    fn from(r: core::ToggleRequest) -> Self {
        Self {
            id: r.id,
            en: r.en,
            n: r.n,
            t: r.t,
            s: r.s,
        }
    }
}

impl From<HotspotToggleRequest> for core::ToggleRequest {
    fn from(r: HotspotToggleRequest) -> Self {
        Self {
            id: r.id,
            en: r.en,
            n: r.n,
            t: r.t,
            s: r.s,
        }
    }
}

/// `nonce` must be a fresh UUID; `signing_seed` is the requester's 32-byte Ed25519 seed.
#[uniffi::export]
pub fn hotspot_request_create(
    requester_id: String,
    enable: bool,
    nonce: String,
    now_ms: i64,
    signing_seed: Vec<u8>,
) -> Result<HotspotToggleRequest, GossipError> {
    let key = SigningKey::from_bytes(&key32(&signing_seed, "signing_seed")?);
    Ok(core::ToggleRequest::create(&requester_id, enable, &nonce, now_ms, &key).into())
}

#[uniffi::export]
pub fn hotspot_request_verify(
    request: HotspotToggleRequest,
    signing_public_key_b64: String,
) -> bool {
    core::ToggleRequest::from(request).is_signature_valid(&signing_public_key_b64)
}

/// Whether the request's clock is inside the freshness window (2 minutes).
#[uniffi::export]
pub fn hotspot_request_is_fresh(request: HotspotToggleRequest, now_ms: i64) -> bool {
    core::ToggleRequest::from(request).is_fresh(now_ms)
}

#[uniffi::export]
pub fn hotspot_request_encode(request: HotspotToggleRequest) -> Vec<u8> {
    core::ToggleRequest::from(request).encode()
}

#[uniffi::export]
pub fn hotspot_request_decode(data: Vec<u8>) -> Option<HotspotToggleRequest> {
    core::ToggleRequest::decode(&data).map(Into::into)
}

/// `hotspot.status`. `cred` is base64(12-byte AES-GCM nonce || ciphertext+tag) when credentials are included.
#[derive(Debug, Clone, uniffi::Record)]
pub struct HotspotStatus {
    pub id: String,
    pub ok: bool,
    pub n: String,
    pub s: String,
    pub cred: Option<String>,
}

impl From<core::Status> for HotspotStatus {
    fn from(s: core::Status) -> Self {
        Self {
            id: s.id,
            ok: s.ok,
            n: s.n,
            s: s.s,
            cred: s.cred,
        }
    }
}

impl From<HotspotStatus> for core::Status {
    fn from(s: HotspotStatus) -> Self {
        Self {
            id: s.id,
            ok: s.ok,
            n: s.n,
            s: s.s,
            cred: s.cred,
        }
    }
}

/// Credentials to include in a status. `shared_key` is from `hotspot_derive_shared_key`; `gcm_nonce` is 12 fresh
/// random bytes.
#[derive(Debug, Clone, uniffi::Record)]
pub struct HotspotCredentials {
    pub ssid: String,
    pub passphrase: String,
    pub shared_key: Vec<u8>,
    pub gcm_nonce: Vec<u8>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct HotspotLogin {
    pub ssid: String,
    pub passphrase: String,
}

/// `SHA-256(DH(local, remote) || "connect-hotspot-gatt-v1")`; `None` for a low-order peer key.
#[uniffi::export]
pub fn hotspot_derive_shared_key(
    local_x25519_secret: Vec<u8>,
    remote_x25519_public: Vec<u8>,
) -> Result<Option<Vec<u8>>, GossipError> {
    let (local, remote) = (
        key32(&local_x25519_secret, "local secret")?,
        key32(&remote_x25519_public, "remote public key")?,
    );
    Ok(core::derive_shared_secret_key(local, remote).map(|k| k.to_vec()))
}

#[uniffi::export]
pub fn hotspot_status_create(
    provider_id: String,
    enabled: bool,
    nonce: String,
    signing_seed: Vec<u8>,
    credentials: Option<HotspotCredentials>,
) -> Result<HotspotStatus, GossipError> {
    let key = SigningKey::from_bytes(&key32(&signing_seed, "signing_seed")?);
    let prepared = match &credentials {
        Some(c) => {
            let shared = key32(&c.shared_key, "shared_key")?;
            let gcm = <[u8; 12]>::try_from(c.gcm_nonce.as_slice())
                .map_err(|_| GossipError::invalid("gcm_nonce must be exactly 12 bytes"))?;
            Some((c.ssid.as_str(), c.passphrase.as_str(), shared, gcm))
        }
        None => None,
    };
    let status = match &prepared {
        Some((ssid, pass, shared, gcm)) => core::Status::create(
            &provider_id,
            enabled,
            &nonce,
            &key,
            Some((ssid, pass, shared, *gcm)),
        ),
        None => core::Status::create(&provider_id, enabled, &nonce, &key, None),
    };
    Ok(status.into())
}

#[uniffi::export]
pub fn hotspot_status_verify(status: HotspotStatus, signing_public_key_b64: String) -> bool {
    core::Status::from(status).is_signature_valid(&signing_public_key_b64)
}

/// Decrypts the credentials; check `hotspot_status_verify` first, this does not.
#[uniffi::export]
pub fn hotspot_status_decrypt(
    status: HotspotStatus,
    shared_key: Vec<u8>,
) -> Result<Option<HotspotLogin>, GossipError> {
    let key = key32(&shared_key, "shared_key")?;
    Ok(core::Status::from(status)
        .decrypt_credentials(&key)
        .map(|(ssid, passphrase)| HotspotLogin { ssid, passphrase }))
}

#[uniffi::export]
pub fn hotspot_status_encode(status: HotspotStatus) -> Vec<u8> {
    core::Status::from(status).encode()
}

#[uniffi::export]
pub fn hotspot_status_decode(data: Vec<u8>) -> Option<HotspotStatus> {
    core::Status::decode(&data).map(Into::into)
}

/// Splits a message into GATT chunks (19 payload bytes each plus a flag byte).
#[uniffi::export]
pub fn hotspot_encode_chunks(message: Vec<u8>) -> Vec<Vec<u8>> {
    core::encode_chunks(&message)
}

/// Reassembles chunks delivered one at a time; discards messages over 4 KiB.
#[derive(uniffi::Object)]
pub struct HotspotChunkReassembler(Mutex<core::ChunkReassembler>);

#[uniffi::export]
impl HotspotChunkReassembler {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self(Mutex::new(core::ChunkReassembler::new())))
    }

    /// The complete message once the last chunk arrives, otherwise `None`.
    pub fn feed(&self, chunk: Vec<u8>) -> Option<Vec<u8>> {
        lock(&self.0).feed(&chunk)
    }
}

/// Admission control for the GATT channel: a per-address rate limit and a seen-nonce set.
#[derive(uniffi::Object)]
pub struct HotspotRequestGate(Mutex<core::RequestGate>);

#[uniffi::export]
impl HotspotRequestGate {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self(Mutex::new(core::RequestGate::new())))
    }

    /// Whether `address` is still under its request budget; counts this attempt. Check before any crypto.
    pub fn allow_rate(&self, address: String, now_ms: i64) -> bool {
        lock(&self.0).allow_rate(&address, now_ms)
    }

    /// True the first time `nonce` is seen, false for a replay. Check after the signature verifies.
    pub fn first_use(&self, nonce: String) -> bool {
        lock(&self.0).first_use(&nonce)
    }
}
