//! The engine as an object: connections, handshakes, pairing, mesh routing, liveness and reconciliation timing.

use std::sync::{Arc, Mutex, MutexGuard};

use ed25519_dalek::SigningKey;
use gossip_core::crypto::noise::StaticKeypair;
use gossip_core::engine::{Core, Identity, PairingIntent};
use gossip_core::env::{Env, SystemEnv};
use gossip_core::features::{Feature, FeatureSettings};
use gossip_core::trust::TrustSnapshot;
use gossip_core::wire::handshake::DeviceType;

use crate::convert::{actions, parse_object, Action, Envelope};
use crate::error::GossipError;

/// An optional clock supplied by the shell, mainly so tests (and simulations) control time. Without one the
/// engine reads the system clock. Randomness always comes from the operating system.
#[uniffi::export(with_foreign)]
pub trait Clock: Send + Sync {
    fn now_ms(&self) -> i64;
}

struct FfiEnv {
    clock: Option<Arc<dyn Clock>>,
    system: SystemEnv,
}

impl Env for FfiEnv {
    fn now_ms(&self) -> i64 {
        match &self.clock {
            Some(c) => c.now_ms(),
            None => self.system.now_ms(),
        }
    }

    fn random_bytes(&mut self, buf: &mut [u8]) {
        self.system.random_bytes(buf);
    }
}

fn key32(bytes: &[u8], what: &str) -> Result<[u8; 32], GossipError> {
    <[u8; 32]>::try_from(bytes)
        .map_err(|_| GossipError::invalid(format!("{what} must be exactly 32 bytes")))
}

fn feature_settings(disabled: &[String]) -> Result<FeatureSettings, GossipError> {
    let mut settings = FeatureSettings::all_enabled();
    for key in disabled {
        let feature = Feature::from_key(key)
            .ok_or_else(|| GossipError::invalid(format!("unknown feature key {key}")))?;
        settings.set_enabled(feature, false);
    }
    Ok(settings)
}

#[derive(uniffi::Object)]
pub struct GossipCore {
    core: Mutex<Core<FfiEnv>>,
}

impl GossipCore {
    fn lock(&self) -> MutexGuard<'_, Core<FfiEnv>> {
        // A panic inside the core while a lock is held would poison it; the state is still consistent
        // (every operation either completes or returns early), so keep going rather than wedging the app.
        self.core.lock().unwrap_or_else(|e| e.into_inner())
    }
}

#[uniffi::export]
impl GossipCore {
    /// - `device_type`: "mac", "android-phone", "android-tablet", "windows" or "linux".
    /// - `noise_secret`: 32-byte X25519 identity secret. `signing_seed`: 32-byte Ed25519 seed.
    /// - `trust_json`: the last `TrustChanged` snapshot, or `None` on first run.
    /// - `disabled_features`: keys of features turned off (see `feature_keys`).
    /// - `clock`: optional time source.
    // A flat argument list is the FFI-friendly shape: foreign callers cannot use builders or Rust structs.
    #[allow(clippy::too_many_arguments)]
    #[uniffi::constructor]
    pub fn new(
        device_id: String,
        device_name: String,
        device_type: String,
        noise_secret: Vec<u8>,
        signing_seed: Vec<u8>,
        trust_json: Option<String>,
        disabled_features: Vec<String>,
        clock: Option<Arc<dyn Clock>>,
    ) -> Result<Arc<Self>, GossipError> {
        if !gossip_core::wire::uuid::is_valid(&device_id) {
            return Err(GossipError::invalid("device_id must be a UUID"));
        }
        let identity = Identity {
            device_id,
            device_name,
            device_type: DeviceType::parse(&device_type),
            noise: StaticKeypair::from_secret_bytes(key32(&noise_secret, "noise_secret")?),
            signing: SigningKey::from_bytes(&key32(&signing_seed, "signing_seed")?),
        };
        let trust = match trust_json {
            Some(json) => serde_json::from_str::<TrustSnapshot>(&json)
                .map_err(|e| GossipError::invalid(format!("trust_json: {e}")))?,
            None => TrustSnapshot::default(),
        };
        let env = FfiEnv {
            clock,
            system: SystemEnv,
        };
        Ok(Arc::new(Self {
            core: Mutex::new(Core::new(
                env,
                identity,
                trust,
                feature_settings(&disabled_features)?,
            )),
        }))
    }

    pub fn device_id(&self) -> String {
        self.lock().device_id().to_owned()
    }

    // ---- Connections ------------------------------------------------------------------------------------------

    /// An inbound connection was accepted.
    pub fn connection_accepted(&self, conn: u64) -> Result<Vec<Action>, GossipError> {
        Ok(actions(self.lock().connection_accepted(conn)?))
    }

    /// An outbound connection to `target` was established. `remote_static` is the target's 32-byte Noise key (from
    /// the trust store or a pairing QR); `pairing_token` is set when this dial is a new pairing.
    pub fn dial(
        &self,
        conn: u64,
        target: String,
        remote_static: Vec<u8>,
        pairing_token: Option<String>,
    ) -> Result<Vec<Action>, GossipError> {
        let key = key32(&remote_static, "remote_static")?;
        Ok(actions(self.lock().dial(
            conn,
            &target,
            key,
            pairing_token.map(|token| PairingIntent { token }),
        )?))
    }

    /// The transport lost the connection (or the app closed it).
    pub fn connection_closed(&self, conn: u64) -> Vec<Action> {
        actions(self.lock().connection_closed(conn))
    }

    /// Closes the live connection to a device, if any.
    pub fn disconnect(&self, device_id: String) -> Vec<Action> {
        actions(self.lock().disconnect(&device_id))
    }

    /// Bytes arrived on a connection: any amount, frames are reassembled inside.
    pub fn bytes_received(&self, conn: u64, bytes: Vec<u8>) -> Vec<Action> {
        actions(self.lock().bytes_received(conn, &bytes))
    }

    pub fn connected_peers(&self) -> Vec<String> {
        self.lock().connected_peers()
    }

    pub fn is_connected(&self, device_id: String) -> bool {
        self.lock().is_connected(&device_id)
    }

    /// Whether a new dial to this device would be accepted (not live, not already being dialed).
    pub fn should_dial(&self, device_id: String) -> bool {
        self.lock().should_dial(&device_id)
    }

    // ---- Pairing and trust ------------------------------------------------------------------------------------

    /// While a pairing QR/code is on screen, an unknown device presenting `token` may be offered to the user.
    pub fn arm_pairing(&self, token: String) {
        self.lock().arm_pairing(&token);
    }

    pub fn disarm_pairing(&self) {
        self.lock().disarm_pairing();
    }

    /// The user answered a `PairingPrompt`.
    pub fn confirm_pairing(&self, conn: u64, accepted: bool) -> Vec<Action> {
        actions(self.lock().confirm_pairing(conn, accepted))
    }

    /// The user removed a device: revokes locally, drops its connection and broadcasts `trust.revoke`.
    pub fn revoke_device(&self, device_id: String) -> Vec<Action> {
        actions(self.lock().revoke_device(&device_id))
    }

    /// Replaces the engine's trust table with the app's current one (the JSON format of `trust_json`). Call it whenever
    /// the app edits its own store directly, e.g. a pairing it started adds a row before dialing. `provisional` lists
    /// rows that are trusted for connecting but must not appear in roster gossip until the other side confirms.
    pub fn set_trust(
        &self,
        trust_json: String,
        provisional: Vec<String>,
    ) -> Result<(), GossipError> {
        let snapshot = serde_json::from_str::<TrustSnapshot>(&trust_json)
            .map_err(|e| GossipError::invalid(format!("trust_json: {e}")))?;
        self.lock().set_trust(snapshot, provisional);
        Ok(())
    }

    /// The trust roster as JSON, exactly what `TrustChanged` carries.
    pub fn trust_json(&self) -> String {
        serde_json::to_string(&self.lock().trust_snapshot()).expect("snapshot serialises")
    }

    // ---- Sending ----------------------------------------------------------------------------------------------

    /// A fresh unsigned envelope from this device (new id, current time, default ttl). Fill in the rest and `send`.
    pub fn new_envelope(&self, kind: String) -> Envelope {
        self.lock().new_envelope(&kind).into()
    }

    /// The `trust.roster_update` for the current roster, targeted at `peer` or broadcast.
    pub fn roster_update(&self, peer: Option<String>) -> Envelope {
        self.lock().roster_update(peer.as_deref()).into()
    }

    /// Originates an envelope: gates on the feature toggle, signs, and sends toward everyone it addresses.
    pub fn send(&self, envelope: Envelope) -> Result<Vec<Action>, GossipError> {
        Ok(actions(self.lock().send(envelope.try_into()?)?))
    }

    /// Like `send`, with a raw follow-up frame (the large-binary-payload convention).
    pub fn send_with_raw(
        &self,
        envelope: Envelope,
        raw: Vec<u8>,
    ) -> Result<Vec<Action>, GossipError> {
        Ok(actions(
            self.lock().send_with_raw(envelope.try_into()?, &raw)?,
        ))
    }

    /// Convenience: a message of `kind` with the given payload JSON, broadcast when `recipient` is `None`.
    pub fn send_message(
        &self,
        kind: String,
        recipient: Option<String>,
        payload_json: String,
    ) -> Result<Vec<Action>, GossipError> {
        let payload = parse_object(&payload_json)?;
        let mut core = self.lock();
        let mut e = core.new_envelope(&kind).with_payload(payload);
        match recipient {
            Some(r) => e = e.to(&r),
            None => e.broadcast = true,
        }
        Ok(actions(core.send(e)?))
    }

    // ---- Time and settings ------------------------------------------------------------------------------------

    /// Drive from a timer (once a second is plenty): heartbeats, stale and stuck-connection cleanup, pairing expiry
    /// and reconciliation.
    pub fn tick(&self) -> Vec<Action> {
        actions(self.lock().tick())
    }

    /// Replaces the set of disabled features (keys from `feature_keys`).
    pub fn set_disabled_features(&self, keys: Vec<String>) -> Result<(), GossipError> {
        self.lock().set_features(feature_settings(&keys)?);
        Ok(())
    }
}

/// Keys of every toggleable feature, in a stable order.
#[uniffi::export]
pub fn feature_keys() -> Vec<String> {
    Feature::ALL.iter().map(|f| f.key().to_owned()).collect()
}

/// The feature that owns a message type, if any (e.g. "clipboard.update" belongs to "clipboard").
#[uniffi::export]
pub fn feature_for_message_type(kind: String) -> Option<String> {
    Feature::for_message_type(&kind).map(|f| f.key().to_owned())
}
