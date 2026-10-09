//! Standalone crypto and small pure helpers the shells need around the engine.

use std::sync::{Mutex, MutexGuard};

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use ed25519_dalek::SigningKey;
use gossip_core::crypto::noise::StaticKeypair;
use gossip_core::crypto::stream::{End, Profile, StreamCipher as CoreStreamCipher};
use gossip_core::crypto::{beacon, pairing};
use gossip_core::env::{Env, SystemEnv};

use crate::error::GossipError;

fn key32(bytes: &[u8], what: &str) -> Result<[u8; 32], GossipError> {
    <[u8; 32]>::try_from(bytes)
        .map_err(|_| GossipError::invalid(format!("{what} must be exactly 32 bytes")))
}

/// A freshly generated device identity. Store the secrets in the platform's secret storage (Keychain, Keystore).
#[derive(Debug, Clone, uniffi::Record)]
pub struct NewIdentity {
    /// A random UUID (version 4).
    pub device_id: String,
    /// 32-byte X25519 secret for Noise.
    pub noise_secret: Vec<u8>,
    /// 32-byte Ed25519 seed for envelope signing.
    pub signing_seed: Vec<u8>,
    /// The matching public keys, ready to put in a pairing QR.
    pub noise_public_key: Vec<u8>,
    pub signing_public_key: Vec<u8>,
}

#[uniffi::export]
pub fn generate_identity() -> NewIdentity {
    let mut env = SystemEnv;
    let noise_secret = env.random_array::<32>();
    let signing_seed = env.random_array::<32>();
    NewIdentity {
        device_id: env.new_uuid(),
        noise_public_key: StaticKeypair::from_secret_bytes(noise_secret)
            .public_bytes()
            .to_vec(),
        signing_public_key: SigningKey::from_bytes(&signing_seed)
            .verifying_key()
            .to_bytes()
            .to_vec(),
        noise_secret: noise_secret.to_vec(),
        signing_seed: signing_seed.to_vec(),
    }
}

/// The X25519 public key for a Noise secret.
#[uniffi::export]
pub fn noise_public_key(noise_secret: Vec<u8>) -> Result<Vec<u8>, GossipError> {
    Ok(
        StaticKeypair::from_secret_bytes(key32(&noise_secret, "noise_secret")?)
            .public_bytes()
            .to_vec(),
    )
}

/// The Ed25519 public key for a signing seed.
#[uniffi::export]
pub fn signing_public_key(signing_seed: Vec<u8>) -> Result<Vec<u8>, GossipError> {
    Ok(
        SigningKey::from_bytes(&key32(&signing_seed, "signing_seed")?)
            .verifying_key()
            .to_bytes()
            .to_vec(),
    )
}

/// A random 32-byte value (beacon keys, session secrets).
#[uniffi::export]
pub fn random_bytes(len: u32) -> Vec<u8> {
    let mut v = vec![0u8; len as usize];
    SystemEnv.random_bytes(&mut v);
    v
}

/// A random version-4 UUID.
#[uniffi::export]
pub fn new_uuid() -> String {
    SystemEnv.new_uuid()
}

// ---- Pairing ---------------------------------------------------------------------------------------------------

/// The six-digit comparison code ("123 456") both screens show, from the two devices' Noise public keys.
#[uniffi::export]
pub fn pairing_code(key_a: Vec<u8>, key_b: Vec<u8>) -> String {
    pairing::code(&key_a, &key_b)
}

/// Whether what the user typed is the displayed code (spaces and separators ignored).
#[uniffi::export]
pub fn pairing_entry_matches(entry: String, expected: String) -> bool {
    pairing::entry_matches(&entry, &expected)
}

/// Constant-time token comparison; `None` on either side never matches.
#[uniffi::export]
pub fn pairing_token_matches(armed: Option<String>, presented: Option<String>) -> bool {
    pairing::token_matches(armed.as_deref(), presented.as_deref())
}

// ---- BLE beacons -----------------------------------------------------------------------------------------------

#[uniffi::export]
pub fn ble_beacon_window(unix_seconds: u64) -> u64 {
    beacon::window(unix_seconds)
}

/// The 8-byte beacon tag for `window`.
#[uniffi::export]
pub fn ble_beacon_tag(key: Vec<u8>, window: u64) -> Vec<u8> {
    beacon::tag(&key, window).to_vec()
}

/// Tags a holder of `key` may be advertising now (one window of clock skew either way).
#[uniffi::export]
pub fn ble_acceptable_tags(key: Vec<u8>, unix_seconds: u64) -> Vec<Vec<u8>> {
    beacon::acceptable_tags(&key, unix_seconds)
        .iter()
        .map(|t| t.to_vec())
        .collect()
}

#[uniffi::export]
pub fn ble_seconds_until_next_window(unix_seconds: u64) -> u64 {
    beacon::seconds_until_next_window(unix_seconds)
}

/// Whether a BLE-advertised key fingerprint identifies `key` (the Mac and Android formats are both accepted).
#[uniffi::export]
pub fn ble_fingerprint_matches(advertised: String, key: Vec<u8>) -> bool {
    gossip_core::trust::fingerprint_matches(&advertised, &key)
}

// ---- Stream cipher ---------------------------------------------------------------------------------------------

/// Which data channel a [`StreamCipher`] protects.
#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum StreamProfile {
    /// Universal Control (direction 1 is controller to device).
    Control,
    /// Screen mirroring (direction 1 is viewer to device).
    Screen,
}

/// The directional counter-nonce AEAD used on the screen and Universal Control WebSockets.
#[derive(uniffi::Object)]
pub struct StreamCipher {
    inner: Mutex<CoreStreamCipher>,
}

impl StreamCipher {
    fn lock(&self) -> MutexGuard<'_, CoreStreamCipher> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }
}

#[uniffi::export]
impl StreamCipher {
    /// `first_end` is true for the Mac / viewer (it sends direction 1); false for the device.
    #[uniffi::constructor]
    pub fn new(
        profile: StreamProfile,
        secret: Vec<u8>,
        session_id: String,
        first_end: bool,
    ) -> std::sync::Arc<Self> {
        let profile = match profile {
            StreamProfile::Control => Profile::CONTROL,
            StreamProfile::Screen => Profile::SCREEN,
        };
        let end = if first_end { End::First } else { End::Second };
        std::sync::Arc::new(Self {
            inner: Mutex::new(CoreStreamCipher::new(profile, &secret, &session_id, end)),
        })
    }

    /// Seals with the next send counter.
    pub fn seal(&self, plaintext: Vec<u8>) -> Result<Vec<u8>, GossipError> {
        self.lock()
            .seal(&plaintext)
            .map_err(|e| GossipError::invalid(e.to_string()))
    }

    /// Opens a message from the other end; fails on a bad length, a replay or an authentication failure.
    pub fn open(&self, message: Vec<u8>) -> Result<Vec<u8>, GossipError> {
        self.lock()
            .open(&message)
            .map_err(|e| GossipError::invalid(e.to_string()))
    }
}

/// Base64 helper for shells that exchange raw keys as text.
#[uniffi::export]
pub fn base64_encode(bytes: Vec<u8>) -> String {
    B64.encode(bytes)
}

#[uniffi::export]
pub fn base64_decode(text: String) -> Result<Vec<u8>, GossipError> {
    B64.decode(text)
        .map_err(|e| GossipError::invalid(e.to_string()))
}
