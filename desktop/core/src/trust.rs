//! The trust roster: who this device trusts, tombstones for revoked devices, and the pure rules for merging a
//! gossiped roster and applying a revocation. Persistence (Keychain, DPAPI, a file) belongs to the shell: it
//! loads a [`TrustSnapshot`] at start and saves one whenever the engine reports a trust change.
//!
//! Rules both apps already follow, and which this module pins down:
//! - A revoked device stays revoked: gossip can never bring it back (an introducer could claim any `addedAt`);
//!   only pairing it directly again clears the tombstone.
//! - Gossip never overwrites an already-trusted row, and never supplies the signing key for an existing row (it
//!   is learned from the device's own authenticated handshake).
//! - A roster message carries at most 64 entries and the store never grows past 64 devices through gossip.
//! - Everything here is idempotent: re-applying the same roster or revocation is a no-op.

use std::collections::BTreeMap;

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};

use crate::wire::handshake::{DeviceType, MAX_DEVICE_NAME_CHARS};
use crate::wire::uuid;

pub const MAX_ENTRIES_PER_MESSAGE: usize = 64;
pub const MAX_TRUSTED_DEVICES: usize = 64;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TrustedDevice {
    pub device_id: String,
    /// Base64 raw X25519 (Noise static) public key.
    pub public_key: String,
    pub device_name: String,
    pub device_type: String,
    /// When this device was added to the roster, ms since the epoch.
    pub added_at: i64,
    /// Base64 raw Ed25519 public key, learned from the device's authenticated handshake.
    pub signing_public_key: Option<String>,
    /// Base64 32-byte BLE beacon key the device shared over the mesh.
    pub beacon_key: Option<String>,
}

/// Everything the shell persists.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TrustSnapshot {
    pub devices: Vec<TrustedDevice>,
    /// `deviceId` to the time it was revoked, ms since the epoch.
    pub revoked: BTreeMap<String, i64>,
}

#[derive(Debug, Clone, Default)]
pub struct TrustStore {
    devices: Vec<TrustedDevice>,
    revoked: BTreeMap<String, i64>,
    /// Devices trusted for the handshake and for verifying their messages, but not yet confirmed by the other side
    /// (a pairing this device started by scanning a QR). In memory only, and kept out of roster gossip so a pairing
    /// that never completes is never announced to the mesh.
    provisional: std::collections::HashSet<String>,
}

/// This device's own entry in a roster message (a recipient meeting the mesh for the first time through a relayed
/// broadcast needs to learn about the sender too, not just the sender's other peers).
#[derive(Debug, Clone)]
pub struct SelfEntry {
    pub device_id: String,
    pub public_key: String,
    pub device_name: String,
    pub device_type: DeviceType,
    pub signing_public_key: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RosterOutcome {
    /// Device ids newly trusted from this roster.
    pub added: Vec<String>,
    /// Tombstoned devices the sender introduced anyway: reply to the sender with a `trust.revoke` for each.
    pub revoke_reminders: Vec<(String, i64)>,
}

impl TrustStore {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn from_snapshot(snapshot: TrustSnapshot) -> Self {
        Self {
            devices: snapshot.devices,
            revoked: snapshot.revoked,
            provisional: Default::default(),
        }
    }

    /// Replaces the whole table, for a shell whose own store is the source of truth for rows it edits directly (the
    /// Android pairing flow adds a provisional row before dialing). `provisional` lists rows excluded from gossip.
    pub fn replace(
        &mut self,
        snapshot: TrustSnapshot,
        provisional: impl IntoIterator<Item = String>,
    ) {
        self.devices = snapshot.devices;
        self.revoked = snapshot.revoked;
        self.provisional = provisional.into_iter().collect();
    }

    pub fn is_provisional(&self, device_id: &str) -> bool {
        self.provisional.contains(device_id)
    }

    pub fn snapshot(&self) -> TrustSnapshot {
        TrustSnapshot {
            devices: self.devices.clone(),
            revoked: self.revoked.clone(),
        }
    }

    pub fn devices(&self) -> &[TrustedDevice] {
        &self.devices
    }

    pub fn device(&self, device_id: &str) -> Option<&TrustedDevice> {
        self.devices.iter().find(|d| d.device_id == device_id)
    }

    pub fn is_trusted(&self, device_id: &str) -> bool {
        self.device(device_id).is_some()
    }

    pub fn revoked_at(&self, device_id: &str) -> Option<i64> {
        self.revoked.get(device_id).copied()
    }

    /// Adds (or replaces) a device, clearing any tombstone: this is the direct-pairing path.
    pub fn add_device(&mut self, device: TrustedDevice) {
        self.devices.retain(|d| d.device_id != device.device_id);
        self.revoked.remove(&device.device_id);
        self.devices.push(device);
    }

    /// Returns whether anything changed.
    pub fn set_signing_public_key(&mut self, device_id: &str, key_b64: &str) -> bool {
        match self.devices.iter_mut().find(|d| d.device_id == device_id) {
            Some(d) if d.signing_public_key.as_deref() != Some(key_b64) => {
                d.signing_public_key = Some(key_b64.to_owned());
                true
            }
            _ => false,
        }
    }

    pub fn set_beacon_key(&mut self, device_id: &str, key_b64: &str) -> bool {
        match self.devices.iter_mut().find(|d| d.device_id == device_id) {
            Some(d) if d.beacon_key.as_deref() != Some(key_b64) => {
                d.beacon_key = Some(key_b64.to_owned());
                true
            }
            _ => false,
        }
    }

    /// Removes the device and records a tombstone; keeps the later of two revocation times.
    pub fn revoke(&mut self, device_id: &str, revoked_at: i64) {
        self.devices.retain(|d| d.device_id != device_id);
        let entry = self
            .revoked
            .entry(device_id.to_owned())
            .or_insert(revoked_at);
        *entry = (*entry).max(revoked_at);
    }

    // ---- Gossip ------------------------------------------------------------------------------------------------

    /// The `trust.roster_update` payload: every trusted device plus this one.
    pub fn roster_payload(&self, me: &SelfEntry) -> Map<String, Value> {
        let mut entries: Vec<Value> = self
            .devices
            .iter()
            .filter(|d| !self.provisional.contains(&d.device_id))
            .map(|d| {
                let mut m = Map::new();
                m.insert("deviceId".into(), d.device_id.clone().into());
                m.insert("publicKey".into(), d.public_key.clone().into());
                m.insert("deviceName".into(), d.device_name.clone().into());
                m.insert("deviceType".into(), d.device_type.clone().into());
                if let Some(k) = &d.signing_public_key {
                    m.insert("signingPublicKey".into(), k.clone().into());
                }
                m.insert("addedAt".into(), d.added_at.into());
                Value::Object(m)
            })
            .collect();
        let mut own = Map::new();
        own.insert("deviceId".into(), me.device_id.clone().into());
        own.insert("publicKey".into(), me.public_key.clone().into());
        own.insert("deviceName".into(), me.device_name.clone().into());
        own.insert("deviceType".into(), me.device_type.as_str().into());
        own.insert(
            "signingPublicKey".into(),
            me.signing_public_key.clone().into(),
        );
        entries.push(Value::Object(own));
        let mut payload = Map::new();
        payload.insert("devices".into(), Value::Array(entries));
        payload
    }

    pub fn revoke_payload(device_id: &str, revoked_at: Option<i64>) -> Map<String, Value> {
        let mut m = Map::new();
        m.insert("deviceId".into(), device_id.to_owned().into());
        if let Some(t) = revoked_at {
            m.insert("revokedAt".into(), t.into());
        }
        m
    }

    /// Applies a gossiped `trust.roster_update`. `added_at` for new rows is `now_ms` (the time this device learned
    /// of them), so a periodic resync never re-stamps an existing row.
    pub fn apply_roster(
        &mut self,
        payload: &Map<String, Value>,
        my_id: &str,
        now_ms: i64,
    ) -> RosterOutcome {
        let mut outcome = RosterOutcome::default();
        let Some(Value::Array(entries)) = payload.get("devices") else {
            return outcome;
        };
        for entry in entries.iter().take(MAX_ENTRIES_PER_MESSAGE) {
            let Some(device_id) = entry.get("deviceId").and_then(Value::as_str) else {
                continue;
            };
            if !uuid::is_valid(device_id) || device_id == my_id || self.is_trusted(device_id) {
                continue;
            }
            if let Some(revoked_at) = self.revoked_at(device_id) {
                outcome
                    .revoke_reminders
                    .push((device_id.to_owned(), revoked_at));
                continue;
            }
            let (Some(public_key), Some(name), Some(kind)) = (
                entry
                    .get("publicKey")
                    .and_then(Value::as_str)
                    .filter(|k| is_valid_key(k)),
                entry.get("deviceName").and_then(Value::as_str),
                entry.get("deviceType").and_then(Value::as_str),
            ) else {
                continue;
            };
            if matches!(DeviceType::parse(kind), DeviceType::Other(_)) {
                continue;
            }
            let signing = entry
                .get("signingPublicKey")
                .and_then(Value::as_str)
                .filter(|k| is_valid_key(k));
            if self.devices.len() >= MAX_TRUSTED_DEVICES {
                break;
            }
            self.add_device(TrustedDevice {
                device_id: device_id.to_owned(),
                public_key: public_key.to_owned(),
                device_name: name.chars().take(MAX_DEVICE_NAME_CHARS).collect(),
                device_type: kind.to_owned(),
                added_at: now_ms,
                signing_public_key: signing.map(str::to_owned),
                beacon_key: None,
            });
            outcome.added.push(device_id.to_owned());
        }
        outcome
    }

    /// Applies a `trust.revoke`. Returns the revoked device id if it names someone other than this device.
    /// `revokedAt` is clamped to `now_ms` so a far-future value cannot make a tombstone un-clearable.
    pub fn apply_revoke(
        &mut self,
        payload: &Map<String, Value>,
        envelope_ts: i64,
        my_id: &str,
        now_ms: i64,
    ) -> Option<String> {
        let device_id = payload.get("deviceId").and_then(Value::as_str)?;
        if !uuid::is_valid(device_id) || device_id == my_id {
            return None;
        }
        let revoked_at = payload
            .get("revokedAt")
            .and_then(Value::as_i64)
            .unwrap_or(envelope_ts)
            .min(now_ms);
        self.revoke(device_id, revoked_at);
        Some(device_id.to_owned())
    }
}

pub fn is_valid_key(base64: &str) -> bool {
    B64.decode(base64).map(|k| k.len() == 32).unwrap_or(false)
}

/// Whether a BLE-advertised fingerprint identifies `key`. Two formats are in use: the Mac's (base64 of the first
/// 8 digest bytes) and Android's (first 16 characters of the unpadded base64 of the whole SHA-256 digest).
pub fn fingerprint_matches(advertised: &str, key: &[u8]) -> bool {
    let digest = Sha256::digest(key);
    let mac_style = B64.encode(&digest[..8]);
    let android_style: String = B64
        .encode(digest)
        .trim_end_matches('=')
        .chars()
        .take(16)
        .collect();
    advertised == mac_style || advertised == android_style
}
