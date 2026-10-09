//! The whole-device state machine: connections, handshakes, trust gating, mesh routing, liveness and
//! reconciliation timing.
//!
//! [`Core`] is sans-IO. The shell owns sockets, discovery and storage; it tells the core what happened
//! ([`Core::bytes_received`], [`Core::connection_closed`], [`Core::tick`], ...) and executes the [`Action`]s that
//! come back (write these bytes to that connection, close it, tell the UI). A connection is just an opaque
//! [`ConnId`] the shell chose; whether it is a TCP socket, a WebSocket through a relay or a test pipe is invisible
//! here, which is what lets one engine serve Mac, Android, Windows, Linux and a relay transport.
//!
//! The policies are the ones the Swift and Kotlin `TransportManager`s already follow:
//! - Handshake frames are capped at 16 KiB, transport frames at 16 MiB.
//! - A trusted peer must present exactly the Noise key it was paired with.
//! - An unknown device is only offered to the user while a pairing is armed (or this side started one), with the
//!   armed token, one prompt at a time.
//! - A responder only promotes a trusted handshake once the peer's first transport frame decrypts (message 1 can
//!   be replayed by anyone who recorded it).
//! - Envelopes are checked for shape, then signature, then de-duplicated, before anything is delivered or relayed.
//! - A raw follow-up frame is always consumed with its metadata envelope, even when discarded.

use std::collections::{HashMap, HashSet};

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use ed25519_dalek::{SigningKey, VerifyingKey};
use serde_json::{Map, Value};
use subtle::ConstantTimeEq;
use thiserror::Error;

use crate::crypto::noise::{Handshake, NoiseError, Role, StaticKeypair, Transport};
use crate::crypto::{pairing, sign};
use crate::env::Env;
use crate::features::FeatureSettings;
use crate::limits::{InboundRateLimiter, PendingFrameQueue};
use crate::mesh::{self, SeenCache};
use crate::reconcile::{Due, Reconciler};
use crate::trust::{SelfEntry, TrustSnapshot, TrustStore, TrustedDevice};
use crate::wire::envelope::{Envelope, DEFAULT_TTL};
use crate::wire::frame::{self, FrameDecoder, MAX_HANDSHAKE_FRAME, MAX_TRANSPORT_FRAME};
use crate::wire::handshake::{self, DeviceType, HandshakeIdentity};

/// Opaque handle for one transport connection, chosen by the shell.
pub type ConnId = u64;

pub const HEARTBEAT_INTERVAL_MS: i64 = 20_000;
pub const HEARTBEAT_TIMEOUT_MS: i64 = 3 * HEARTBEAT_INTERVAL_MS;
/// A connection that has not finished its handshake (or first proof frame) by then is closed.
pub const HANDSHAKE_TIMEOUT_MS: i64 = 15_000;
/// How long the user has to answer a pairing prompt.
pub const CONFIRMATION_TIMEOUT_MS: i64 = 90_000;
/// How long an armed pairing QR/code stays valid.
pub const PAIRING_ARM_DURATION_MS: i64 = 300_000;
/// Consecutive undecryptable frames tolerated before a connection is considered corrupt.
const MAX_CONSECUTIVE_DECRYPT_FAILURES: u32 = 16;

/// This device's long-term identity.
pub struct Identity {
    pub device_id: String,
    pub device_name: String,
    pub device_type: DeviceType,
    /// X25519 key used for Noise.
    pub noise: StaticKeypair,
    /// Ed25519 key used to sign envelopes.
    pub signing: SigningKey,
}

impl Identity {
    fn handshake_identity(&self, pairing_token: Option<String>) -> HandshakeIdentity {
        HandshakeIdentity {
            device_id: self.device_id.clone(),
            device_name: self.device_name.clone(),
            device_type: self.device_type.as_str().to_owned(),
            signing_public_key: B64.encode(self.signing.verifying_key().to_bytes()),
            pairing_token,
        }
    }

    fn self_entry(&self) -> SelfEntry {
        SelfEntry {
            device_id: self.device_id.clone(),
            public_key: B64.encode(self.noise.public_bytes()),
            device_name: self.device_name.clone(),
            device_type: self.device_type.clone(),
            signing_public_key: B64.encode(self.signing.verifying_key().to_bytes()),
        }
    }
}

/// Who a handshake says the peer is (authenticated by the Noise payload).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PeerInfo {
    pub device_id: String,
    pub device_name: String,
    pub device_type: DeviceType,
    pub signing_public_key: [u8; 32],
    /// The peer's Noise static key.
    pub noise_public_key: [u8; 32],
}

/// What the shell must do. Returned from every input method.
#[derive(Debug, Clone, PartialEq)]
pub enum Action {
    /// Write these bytes (already length-framed) to the connection.
    Send {
        conn: ConnId,
        bytes: Vec<u8>,
    },
    /// Close the connection. The core has already forgotten it.
    Close {
        conn: ConnId,
    },
    Event(Event),
}

#[derive(Debug, Clone, PartialEq)]
pub enum Event {
    /// A peer finished connecting and is now live on `conn`. `newly_paired` is true for a just-confirmed pairing.
    PeerConnected {
        conn: ConnId,
        peer: PeerInfo,
        newly_paired: bool,
    },
    PeerDisconnected {
        device_id: String,
    },
    /// An unknown device needs the user's confirmation; answer with [`Core::confirm_pairing`]. `code` is the
    /// six-digit comparison code both screens show.
    PairingPrompt {
        conn: ConnId,
        peer: PeerInfo,
        code: String,
    },
    /// The prompt for `conn` is no longer valid (peer left or timed out).
    PairingPromptCancelled {
        conn: ConnId,
    },
    /// An envelope for a feature handler. `raw` is the follow-up frame when `envelope.has_raw_followup`.
    Deliver {
        envelope: Envelope,
        raw: Option<Vec<u8>>,
    },
    /// Any validated message from a device proves it is reachable, even when relayed.
    Heard {
        device_id: String,
    },
    /// The trust roster changed: persist this snapshot.
    TrustChanged(TrustSnapshot),
    /// A trusted peer's connection was dropped because the device was revoked.
    DeviceRevoked {
        device_id: String,
    },
    /// A reconciliation resend is due; the owning feature answers it.
    ReconcileDue(Due),
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum SendError {
    #[error("not connected to any peer that can receive this")]
    NotConnected,
    #[error("message too large")]
    TooLarge,
    #[error("payload cannot be signed: {0}")]
    Unsignable(String),
    #[error("encryption failed")]
    Encryption,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum DialError {
    #[error("already connected to that device")]
    AlreadyConnected,
    #[error("a dial to that device is already in progress")]
    AlreadyDialing,
    #[error("connection id already in use")]
    DuplicateConnection,
    #[error("handshake failed to start: {0}")]
    Handshake(NoiseError),
}

/// Why this side is dialing a device it may not trust yet (it scanned a QR or typed a code).
#[derive(Debug, Clone)]
pub struct PairingIntent {
    pub token: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Stage {
    /// Responder: waiting for `handshake.hello`.
    AwaitingHello,
    /// Initiator: waiting for `handshake.ack`.
    AwaitingAck,
    /// Handshake done, waiting for the user to confirm a new device.
    AwaitingConfirm,
    /// Responder, trusted: handshake done, waiting for the first transport frame to prove key possession.
    AwaitingProof,
    Live,
}

struct RawPending {
    envelope: Envelope,
    deliver: bool,
    forward_to: Vec<String>,
    /// Drain and discard the raw frame (the metadata was rejected or a duplicate).
    discard: bool,
}

struct Conn {
    role: Role,
    stage: Stage,
    decoder: FrameDecoder,
    handshake: Option<Handshake>,
    transport: Option<Transport>,
    peer: Option<PeerInfo>,
    presented_pairing_token: Option<String>,
    /// Initiator side: the device id this connection was dialed for.
    dial_target: Option<String>,
    /// Initiator side: this dial is a new pairing.
    pairing_intent: bool,
    rate: InboundRateLimiter,
    queued: PendingFrameQueue,
    raw_pending: Option<RawPending>,
    opened_ms: i64,
    stage_since_ms: i64,
    last_received_ms: i64,
    last_heartbeat_ms: i64,
    decrypt_failures: u32,
}

impl Conn {
    fn new(role: Role, stage: Stage, now: i64) -> Self {
        Self {
            role,
            stage,
            decoder: FrameDecoder::new(MAX_HANDSHAKE_FRAME),
            handshake: None,
            transport: None,
            peer: None,
            presented_pairing_token: None,
            dial_target: None,
            pairing_intent: false,
            rate: InboundRateLimiter::default(),
            queued: PendingFrameQueue::default(),
            raw_pending: None,
            opened_ms: now,
            stage_since_ms: now,
            last_received_ms: now,
            last_heartbeat_ms: now,
            decrypt_failures: 0,
        }
    }
}

pub struct Core<E: Env> {
    env: E,
    identity: Identity,
    trust: TrustStore,
    features: FeatureSettings,
    conns: HashMap<ConnId, Conn>,
    /// Live peers by device id.
    peers: HashMap<String, ConnId>,
    dialing: HashSet<String>,
    seen: SeenCache,
    reconciler: Reconciler,
    armed_pairing: Option<(String, i64)>,
    prompt_active: bool,
}

type Out = Vec<Action>;

impl<E: Env> Core<E> {
    pub fn new(
        env: E,
        identity: Identity,
        trust: TrustSnapshot,
        features: FeatureSettings,
    ) -> Self {
        Self {
            env,
            identity,
            trust: TrustStore::from_snapshot(trust),
            features,
            conns: HashMap::new(),
            peers: HashMap::new(),
            dialing: HashSet::new(),
            seen: SeenCache::default(),
            reconciler: Reconciler::default(),
            armed_pairing: None,
            prompt_active: false,
        }
    }

    // ---- Accessors --------------------------------------------------------------------------------------------

    pub fn device_id(&self) -> &str {
        &self.identity.device_id
    }

    pub fn env(&self) -> &E {
        &self.env
    }

    pub fn env_mut(&mut self) -> &mut E {
        &mut self.env
    }

    pub fn trust(&self) -> &TrustStore {
        &self.trust
    }

    pub fn trust_snapshot(&self) -> TrustSnapshot {
        self.trust.snapshot()
    }

    /// Replaces the trust table with the shell's current one. For rows the shell edits itself (a pairing it started
    /// adds a provisional row before dialing). `provisional` rows are trusted for connecting but not announced in
    /// roster gossip. Changes nothing about live connections and reports no `TrustChanged` (the shell made the change).
    pub fn set_trust(&mut self, snapshot: TrustSnapshot, provisional: Vec<String>) {
        self.trust.replace(snapshot, provisional);
    }

    pub fn features(&self) -> &FeatureSettings {
        &self.features
    }

    pub fn set_features(&mut self, features: FeatureSettings) {
        self.features = features;
    }

    /// Device ids with a live connection.
    pub fn connected_peers(&self) -> Vec<String> {
        let mut ids: Vec<String> = self.peers.keys().cloned().collect();
        ids.sort();
        ids
    }

    pub fn is_connected(&self, device_id: &str) -> bool {
        self.peers.contains_key(device_id)
    }

    /// Whether a new dial to `device_id` would be accepted (not live, not already being dialed).
    pub fn should_dial(&self, device_id: &str) -> bool {
        !self.peers.contains_key(device_id) && !self.dialing.contains(device_id)
    }

    /// A fresh unsigned envelope from this device: new id, current time, default ttl.
    pub fn new_envelope(&mut self, kind: &str) -> Envelope {
        let id = self.env.new_uuid();
        Envelope::new(id, kind, &self.identity.device_id, self.env.now_ms())
    }

    // ---- Connection lifecycle ---------------------------------------------------------------------------------

    /// An inbound connection was accepted.
    pub fn connection_accepted(&mut self, conn: ConnId) -> Result<Out, DialError> {
        if self.conns.contains_key(&conn) {
            return Err(DialError::DuplicateConnection);
        }
        let now = self.env.now_ms();
        let mut c = Conn::new(Role::Responder, Stage::AwaitingHello, now);
        c.handshake = Some(Handshake::responder(&self.identity.noise, &[]));
        self.conns.insert(conn, c);
        Ok(Vec::new())
    }

    /// An outbound connection to `target` was established and the handshake should start. `remote_static` is the
    /// target's Noise key, from the trust store or a pairing QR. `pairing` is set when this dial is a new pairing.
    pub fn dial(
        &mut self,
        conn: ConnId,
        target: &str,
        remote_static: [u8; 32],
        pairing: Option<PairingIntent>,
    ) -> Result<Out, DialError> {
        if self.conns.contains_key(&conn) {
            return Err(DialError::DuplicateConnection);
        }
        if self.peers.contains_key(target) {
            return Err(DialError::AlreadyConnected);
        }
        if !self.dialing.insert(target.to_owned()) {
            return Err(DialError::AlreadyDialing);
        }
        let now = self.env.now_ms();
        let mut c = Conn::new(Role::Initiator, Stage::AwaitingAck, now);
        c.dial_target = Some(target.to_owned());
        c.pairing_intent = pairing.is_some();
        let identity = self.identity.handshake_identity(pairing.map(|p| p.token));
        let mut hs = Handshake::initiator(&self.identity.noise, remote_static, &[]);
        let ephemeral = self.env.random_array::<32>();
        let msg1 = match hs.write_message1(&identity.encode(), ephemeral) {
            Ok(m) => m,
            Err(e) => {
                self.dialing.remove(target);
                return Err(DialError::Handshake(e));
            }
        };
        c.handshake = Some(hs);
        self.conns.insert(conn, c);
        let id = self.env.new_uuid();
        let hello = handshake::handshake_envelope(
            handshake::HELLO,
            id,
            &self.identity.device_id,
            None,
            now,
            &msg1,
        );
        Ok(vec![Action::Send {
            conn,
            bytes: frame::encode(&hello.encode()),
        }])
    }

    /// The shell lost the connection (or the user closed it).
    pub fn connection_closed(&mut self, conn: ConnId) -> Out {
        let mut out = Vec::new();
        self.drop_conn(conn, false, &mut out);
        out
    }

    /// Closes the live connection to `device_id`, if any.
    pub fn disconnect(&mut self, device_id: &str) -> Out {
        let mut out = Vec::new();
        if let Some(conn) = self.peers.get(device_id).copied() {
            self.drop_conn(conn, true, &mut out);
        }
        out
    }

    /// Removes a connection, emitting the events that follow from it. `close` also tells the shell to close it.
    fn drop_conn(&mut self, conn: ConnId, close: bool, out: &mut Out) {
        let Some(c) = self.conns.remove(&conn) else {
            return;
        };
        if c.stage == Stage::AwaitingConfirm {
            self.prompt_active = false;
            out.push(Action::Event(Event::PairingPromptCancelled { conn }));
        }
        if let Some(target) = &c.dial_target {
            self.dialing.remove(target);
        }
        if c.stage == Stage::Live {
            if let Some(peer) = &c.peer {
                if self.peers.get(&peer.device_id) == Some(&conn) {
                    self.peers.remove(&peer.device_id);
                    out.push(Action::Event(Event::PeerDisconnected {
                        device_id: peer.device_id.clone(),
                    }));
                }
            }
        }
        if close {
            out.push(Action::Close { conn });
        }
    }

    // ---- Pairing -----------------------------------------------------------------------------------------------

    /// While a pairing QR/code is on screen, an unknown device presenting `token` may be offered to the user.
    pub fn arm_pairing(&mut self, token: &str) {
        self.armed_pairing = Some((
            token.to_owned(),
            self.env.now_ms() + PAIRING_ARM_DURATION_MS,
        ));
    }

    pub fn disarm_pairing(&mut self) {
        self.armed_pairing = None;
    }

    fn pairing_allows(&self, presented: Option<&str>) -> bool {
        match &self.armed_pairing {
            Some((token, expires)) => {
                self.env.now_ms() < *expires && pairing::token_matches(Some(token), presented)
            }
            None => false,
        }
    }

    /// The user answered a [`Event::PairingPrompt`].
    pub fn confirm_pairing(&mut self, conn: ConnId, accepted: bool) -> Out {
        let mut out = Vec::new();
        let waiting = self
            .conns
            .get(&conn)
            .is_some_and(|c| c.stage == Stage::AwaitingConfirm);
        if !waiting {
            return out;
        }
        self.prompt_active = false;
        if !accepted {
            self.drop_conn(conn, true, &mut out);
            return out;
        }
        let peer = self.conns[&conn]
            .peer
            .clone()
            .expect("a confirming connection has a peer");
        self.trust.add_device(TrustedDevice {
            device_id: peer.device_id.clone(),
            public_key: B64.encode(peer.noise_public_key),
            device_name: peer
                .device_name
                .chars()
                .take(crate::wire::handshake::MAX_DEVICE_NAME_CHARS)
                .collect(),
            device_type: peer.device_type.as_str().to_owned(),
            added_at: self.env.now_ms(),
            signing_public_key: Some(B64.encode(peer.signing_public_key)),
            beacon_key: None,
        });
        out.push(Action::Event(Event::TrustChanged(self.trust.snapshot())));
        self.promote(conn, true, &mut out);
        out
    }

    // ---- Receiving ---------------------------------------------------------------------------------------------

    /// Bytes arrived on a connection (any amount; frames are reassembled here).
    pub fn bytes_received(&mut self, conn: ConnId, bytes: &[u8]) -> Out {
        let mut out = Vec::new();
        let Some(c) = self.conns.get_mut(&conn) else {
            return out;
        };
        c.decoder.push(bytes);
        while let Some(c) = self.conns.get_mut(&conn) {
            match c.decoder.next_frame() {
                Ok(Some(payload)) => self.handle_frame(conn, payload, &mut out),
                Ok(None) => break,
                Err(_) => {
                    self.drop_conn(conn, true, &mut out);
                    break;
                }
            }
        }
        out
    }

    fn handle_frame(&mut self, conn: ConnId, payload: Vec<u8>, out: &mut Out) {
        let Some(stage) = self.conns.get(&conn).map(|c| c.stage) else {
            return;
        };
        match stage {
            Stage::AwaitingHello => self.handle_hello(conn, &payload, out),
            Stage::AwaitingAck => self.handle_ack(conn, &payload, out),
            Stage::AwaitingConfirm => {
                let queued = self
                    .conns
                    .get_mut(&conn)
                    .map(|c| c.queued.enqueue(payload))
                    .unwrap_or(true);
                if !queued {
                    self.drop_conn(conn, true, out);
                }
            }
            Stage::AwaitingProof => self.handle_proof_frame(conn, &payload, out),
            Stage::Live => self.process_transport_frame(conn, &payload, out),
        }
    }

    /// Responder: `handshake.hello` carrying Noise message 1.
    fn handle_hello(&mut self, conn: ConnId, payload: &[u8], out: &mut Out) {
        let result = (|| -> Result<(), ()> {
            let hello = Envelope::decode(payload).map_err(|_| ())?;
            let msg1 = handshake::noise_bytes(&hello, handshake::HELLO).map_err(|_| ())?;
            let c = self.conns.get_mut(&conn).ok_or(())?;
            let hs = c.handshake.as_mut().ok_or(())?;
            let identity_bytes = hs.read_message1(&msg1).map_err(|_| ())?;
            let claimed = HandshakeIdentity::decode(&identity_bytes).map_err(|_| ())?;
            // Identity comes from the authenticated Noise payload, not the plaintext envelope.
            if claimed.device_id != hello.sender_id {
                return Err(());
            }
            let noise_public_key = hs.remote_static().ok_or(())?;
            c.peer = Some(peer_info(&claimed, noise_public_key));
            c.presented_pairing_token = claimed.pairing_token.clone();

            let ephemeral = self.env.random_array::<32>();
            let reply_identity = self.identity.handshake_identity(None).encode();
            let c = self.conns.get_mut(&conn).ok_or(())?;
            let hs = c.handshake.as_mut().ok_or(())?;
            let (msg2, transport) = hs
                .write_message2(&reply_identity, ephemeral)
                .map_err(|_| ())?;
            c.transport = Some(transport);
            c.handshake = None;
            c.decoder.set_limit(MAX_TRANSPORT_FRAME);

            let id = self.env.new_uuid();
            let now = self.env.now_ms();
            let ack = handshake::handshake_envelope(
                handshake::ACK,
                id,
                &self.identity.device_id,
                Some(&hello.sender_id),
                now,
                &msg2,
            );
            out.push(Action::Send {
                conn,
                bytes: frame::encode(&ack.encode()),
            });
            Ok(())
        })();
        match result {
            Ok(()) => self.finalize_handshake(conn, out),
            Err(()) => self.drop_conn(conn, true, out),
        }
    }

    /// Initiator: `handshake.ack` carrying Noise message 2.
    fn handle_ack(&mut self, conn: ConnId, payload: &[u8], out: &mut Out) {
        let result = (|| -> Result<(), ()> {
            let ack = Envelope::decode(payload).map_err(|_| ())?;
            let msg2 = handshake::noise_bytes(&ack, handshake::ACK).map_err(|_| ())?;
            let c = self.conns.get_mut(&conn).ok_or(())?;
            let hs = c.handshake.as_mut().ok_or(())?;
            let (identity_bytes, transport) = hs.read_message2(&msg2).map_err(|_| ())?;
            let claimed = HandshakeIdentity::decode(&identity_bytes).map_err(|_| ())?;
            if claimed.device_id != ack.sender_id {
                return Err(());
            }
            // We dialed a specific device with its pinned key; a different identity answering is wrong.
            if c.dial_target
                .as_deref()
                .is_some_and(|t| t != claimed.device_id)
            {
                return Err(());
            }
            let noise_public_key = hs.remote_static().ok_or(())?;
            c.peer = Some(peer_info(&claimed, noise_public_key));
            c.transport = Some(transport);
            c.handshake = None;
            c.decoder.set_limit(MAX_TRANSPORT_FRAME);
            Ok(())
        })();
        match result {
            Ok(()) => self.finalize_handshake(conn, out),
            Err(()) => self.drop_conn(conn, true, out),
        }
    }

    /// The Noise handshake is complete on this side; decide what the peer is allowed to become.
    fn finalize_handshake(&mut self, conn: ConnId, out: &mut Out) {
        let now = self.env.now_ms();
        let Some(c) = self.conns.get(&conn) else {
            return;
        };
        let (Some(peer), role, pairing_intent, presented) = (
            c.peer.clone(),
            c.role,
            c.pairing_intent,
            c.presented_pairing_token.clone(),
        ) else {
            return self.drop_conn(conn, true, out);
        };

        if let Some(stored) = self.trust.device(&peer.device_id) {
            // The claimed id travels in plaintext; only the Noise key is authenticated, so it must be the paired key.
            if !keys_match(&stored.public_key, &peer.noise_public_key) {
                return self.drop_conn(conn, true, out);
            }
            if role == Role::Responder {
                // Wait for the first transport frame before touching any existing connection.
                self.set_stage(conn, Stage::AwaitingProof, now);
                return;
            }
            return self.promote(conn, false, out);
        }

        // Unknown device: the responder needs an armed pairing and the right token; the initiator needs to have
        // started a pairing itself. Either way only one prompt may be open.
        let allowed = match role {
            Role::Responder => self.pairing_allows(presented.as_deref()),
            Role::Initiator => pairing_intent,
        };
        if !allowed || self.prompt_active {
            return self.drop_conn(conn, true, out);
        }
        self.prompt_active = true;
        self.armed_pairing = None; // single use
        self.set_stage(conn, Stage::AwaitingConfirm, now);
        let code = pairing::code(&self.identity.noise.public_bytes(), &peer.noise_public_key);
        out.push(Action::Event(Event::PairingPrompt { conn, peer, code }));
    }

    fn set_stage(&mut self, conn: ConnId, stage: Stage, now: i64) {
        if let Some(c) = self.conns.get_mut(&conn) {
            c.stage = stage;
            c.stage_since_ms = now;
        }
    }

    /// First transport frame from a trusted responder-side peer: it must decrypt before the peer is promoted.
    fn handle_proof_frame(&mut self, conn: ConnId, payload: &[u8], out: &mut Out) {
        let plaintext = self
            .conns
            .get_mut(&conn)
            .and_then(|c| c.transport.as_mut())
            .and_then(|t| t.decrypt(payload).ok());
        let Some(plaintext) = plaintext else {
            return self.drop_conn(conn, true, out);
        };
        self.promote(conn, false, out);
        if self
            .conns
            .get(&conn)
            .is_some_and(|c| c.stage == Stage::Live)
        {
            self.process_plaintext(conn, plaintext, out);
        }
    }

    /// The connection becomes a live peer: it replaces any stale connection for the same device, the signing key
    /// from the authenticated handshake is recorded, and presence plus on-connect reconciliation start.
    fn promote(&mut self, conn: ConnId, newly_paired: bool, out: &mut Out) {
        let now = self.env.now_ms();
        let Some(c) = self.conns.get_mut(&conn) else {
            return;
        };
        let Some(peer) = c.peer.clone() else { return };
        c.stage = Stage::Live;
        c.stage_since_ms = now;
        c.last_received_ms = now;
        c.last_heartbeat_ms = now;
        if let Some(target) = c.dial_target.clone() {
            self.dialing.remove(&target);
        }

        if self
            .trust
            .set_signing_public_key(&peer.device_id, &B64.encode(peer.signing_public_key))
        {
            out.push(Action::Event(Event::TrustChanged(self.trust.snapshot())));
        }

        if let Some(stale) = self.peers.insert(peer.device_id.clone(), conn) {
            if stale != conn {
                // Replace the old connection without announcing a disconnect/connect flap for the same device.
                if let Some(old) = self.conns.remove(&stale) {
                    if let Some(t) = &old.dial_target {
                        self.dialing.remove(t);
                    }
                }
                out.push(Action::Close { conn: stale });
            }
        }

        out.push(Action::Event(Event::PeerConnected {
            conn,
            peer: peer.clone(),
            newly_paired,
        }));
        // Presence, then the on-connect reconciliation sends for this peer.
        let presence = self.new_envelope("presence.online").broadcast();
        let _ = self.send_into(presence, &mut Vec::new(), out);
        for due in self.reconciler.on_peer_connected(&peer.device_id) {
            out.push(Action::Event(Event::ReconcileDue(due)));
        }

        // Frames that arrived while the user was confirming are decrypted now, in order.
        let queued = self
            .conns
            .get_mut(&conn)
            .map(|c| c.queued.drain())
            .unwrap_or_default();
        for payload in queued {
            if !self.conns.contains_key(&conn) {
                break;
            }
            self.process_transport_frame(conn, &payload, out);
        }
    }

    fn process_transport_frame(&mut self, conn: ConnId, payload: &[u8], out: &mut Out) {
        let now = self.env.now_ms();
        let Some(c) = self.conns.get_mut(&conn) else {
            return;
        };
        c.last_received_ms = now;
        if !c.rate.allow(now) {
            return self.drop_conn(conn, true, out);
        }
        let Some(transport) = c.transport.as_mut() else {
            return;
        };
        match transport.decrypt(payload) {
            Ok(plaintext) => {
                c.decrypt_failures = 0;
                self.process_plaintext(conn, plaintext, out);
            }
            Err(_) => {
                c.decrypt_failures += 1;
                if c.decrypt_failures >= MAX_CONSECUTIVE_DECRYPT_FAILURES {
                    self.drop_conn(conn, true, out);
                }
            }
        }
    }

    fn process_plaintext(&mut self, conn: ConnId, plaintext: Vec<u8>, out: &mut Out) {
        let Some(c) = self.conns.get_mut(&conn) else {
            return;
        };
        let Some(arrived_from) = c.peer.as_ref().map(|p| p.device_id.clone()) else {
            return;
        };
        // A raw follow-up frame armed by the previous metadata envelope: not JSON, so check before decoding.
        if let Some(pending) = c.raw_pending.take() {
            return self.finish_raw(pending, plaintext, &arrived_from, out);
        }
        // One undecodable message must not take the connection (and what is relayed over it) down.
        if let Ok(envelope) = Envelope::decode(&plaintext) {
            self.handle_received_envelope(conn, envelope, &arrived_from, out);
        }
    }

    fn arm_raw(&mut self, conn: ConnId, pending: RawPending) {
        if let Some(c) = self.conns.get_mut(&conn) {
            c.raw_pending = Some(pending);
        }
    }

    /// The mesh decision for one decoded inbound envelope.
    fn handle_received_envelope(
        &mut self,
        conn: ConnId,
        received: Envelope,
        arrived_from: &str,
        out: &mut Out,
    ) {
        let now = self.env.now_ms();
        let mut envelope = received;
        envelope.ttl = mesh::clamp_ttl(envelope.ttl);

        let discard = |this: &mut Self, envelope: Envelope| {
            if envelope.has_raw_followup {
                this.arm_raw(
                    conn,
                    RawPending {
                        envelope,
                        deliver: false,
                        forward_to: Vec::new(),
                        discard: true,
                    },
                );
            }
        };

        // Shape and signature first, so a forged copy can neither be acted on, relayed, nor poison the seen cache.
        if !envelope.is_well_formed(now) || !self.is_authentic(&envelope) {
            return discard(self, envelope);
        }
        if envelope.sender_id != self.identity.device_id {
            out.push(Action::Event(Event::Heard {
                device_id: envelope.sender_id.clone(),
            }));
        }
        if !self.seen.record(&envelope.id) {
            return discard(self, envelope);
        }

        let peers: Vec<String> = self.peers.keys().cloned().collect();
        let routing = mesh::route_received(
            &envelope,
            arrived_from,
            &self.identity.device_id,
            peers.iter().map(String::as_str),
        );

        if envelope.has_raw_followup {
            // Delivery and forwarding both wait for the raw frame, so a relay always forwards the pair atomically.
            self.arm_raw(
                conn,
                RawPending {
                    envelope,
                    deliver: routing.deliver,
                    forward_to: routing.forward_to,
                    discard: false,
                },
            );
            return;
        }
        if routing.deliver {
            self.deliver(&envelope, None, out);
        }
        for target in &routing.forward_to {
            let forwarded = envelope.with_forward_ttl(routing.forward_ttl);
            let _ = self.send_envelope_to(target, &forwarded, None, out);
        }
    }

    fn finish_raw(
        &mut self,
        pending: RawPending,
        raw: Vec<u8>,
        _arrived_from: &str,
        out: &mut Out,
    ) {
        if pending.discard {
            return;
        }
        // The raw frame is outside the signature; the signed payload carries its hash.
        if !pending.envelope.raw_frame_matches(&raw) {
            return;
        }
        let ttl = pending.envelope.ttl - 1;
        if pending.deliver {
            self.deliver(&pending.envelope, Some(raw.clone()), out);
        }
        for target in &pending.forward_to {
            let forwarded = pending.envelope.with_forward_ttl(ttl);
            let _ = self.send_envelope_to(target, &forwarded, Some(&raw), out);
        }
    }

    /// Handles the infrastructure types itself; everything else goes to the feature handlers.
    fn deliver(&mut self, envelope: &Envelope, raw: Option<Vec<u8>>, out: &mut Out) {
        match envelope.kind.as_str() {
            "trust.roster_update" => return self.handle_roster_update(envelope, out),
            "trust.revoke" => return self.handle_revoke(envelope, out),
            _ => {}
        }
        // A feature turned off on this device never reaches its handlers.
        if !self.features.is_message_allowed(&envelope.kind) {
            return;
        }
        out.push(Action::Event(Event::Deliver {
            envelope: envelope.clone(),
            raw,
        }));
    }

    fn is_authentic(&self, envelope: &Envelope) -> bool {
        let key = if envelope.sender_id == self.identity.device_id {
            Some(self.identity.signing.verifying_key())
        } else {
            self.trust
                .device(&envelope.sender_id)
                .and_then(|d| d.signing_public_key.as_deref())
                .and_then(|k| B64.decode(k).ok())
                .and_then(|k| <[u8; 32]>::try_from(k).ok())
                .and_then(|k| VerifyingKey::from_bytes(&k).ok())
        };
        key.is_some_and(|k| sign::verify(envelope, &k))
    }

    // ---- Trust gossip ------------------------------------------------------------------------------------------

    fn handle_roster_update(&mut self, envelope: &Envelope, out: &mut Out) {
        let now = self.env.now_ms();
        let outcome = self
            .trust
            .apply_roster(&envelope.payload, &self.identity.device_id, now);
        if !outcome.added.is_empty() {
            out.push(Action::Event(Event::TrustChanged(self.trust.snapshot())));
        }
        // A peer still introducing a revoked device missed the revoke: tell it again.
        for (device_id, revoked_at) in outcome.revoke_reminders {
            let reminder = self
                .new_envelope("trust.revoke")
                .to(&envelope.sender_id)
                .with_payload(TrustStore::revoke_payload(&device_id, Some(revoked_at)));
            let _ = self.send_into(reminder, &mut Vec::new(), out);
        }
    }

    fn handle_revoke(&mut self, envelope: &Envelope, out: &mut Out) {
        let now = self.env.now_ms();
        let Some(device_id) = self.trust.apply_revoke(
            &envelope.payload,
            envelope.ts,
            &self.identity.device_id,
            now,
        ) else {
            return;
        };
        out.push(Action::Event(Event::TrustChanged(self.trust.snapshot())));
        out.push(Action::Event(Event::DeviceRevoked {
            device_id: device_id.clone(),
        }));
        if let Some(conn) = self.peers.get(&device_id).copied() {
            self.drop_conn(conn, true, out);
        }
    }

    /// The `trust.roster_update` for this device's current roster, targeted at `peer` or broadcast.
    pub fn roster_update(&mut self, peer: Option<&str>) -> Envelope {
        let payload = self.trust.roster_payload(&self.identity.self_entry());
        let mut e = self
            .new_envelope("trust.roster_update")
            .with_payload(payload);
        match peer {
            Some(p) => e = e.to(p),
            None => e.broadcast = true,
        }
        e
    }

    /// The user removed a device: revoke locally, drop its connection and broadcast `trust.revoke`.
    pub fn revoke_device(&mut self, device_id: &str) -> Out {
        let mut out = Vec::new();
        let now = self.env.now_ms();
        self.trust.revoke(device_id, now);
        out.push(Action::Event(Event::TrustChanged(self.trust.snapshot())));
        if let Some(conn) = self.peers.get(device_id).copied() {
            self.drop_conn(conn, true, &mut out);
        }
        let revoke =
            self.new_envelope("trust.revoke")
                .broadcast()
                .with_payload(TrustStore::revoke_payload(
                    device_id,
                    self.trust.revoked_at(device_id),
                ));
        let _ = self.send_into(revoke, &mut Vec::new(), &mut out);
        out
    }

    // ---- Sending -----------------------------------------------------------------------------------------------

    /// Originates `envelope`: gates on the feature toggle, signs it, records its id as seen and sends it toward
    /// everyone it addresses. Sending nothing because the feature is off is not an error.
    pub fn send(&mut self, envelope: Envelope) -> Result<Out, SendError> {
        let mut out = Vec::new();
        self.send_into(envelope, &mut Vec::new(), &mut out)?;
        Ok(out)
    }

    /// Like [`Core::send`] with a raw follow-up frame (the "large binary payload" convention). The raw frame's hash
    /// is added to the signed payload.
    pub fn send_with_raw(&mut self, mut envelope: Envelope, raw: &[u8]) -> Result<Out, SendError> {
        let mut out = Vec::new();
        if !self.features.is_message_allowed(&envelope.kind) {
            return Ok(out);
        }
        envelope.has_raw_followup = true;
        let envelope = envelope.binding_raw_frame(raw);
        self.originate(envelope, Some(raw), &mut out)?;
        Ok(out)
    }

    fn send_into(
        &mut self,
        envelope: Envelope,
        _scratch: &mut Out,
        out: &mut Out,
    ) -> Result<(), SendError> {
        if !self.features.is_message_allowed(&envelope.kind) {
            return Ok(());
        }
        self.originate(envelope, None, out)
    }

    fn originate(
        &mut self,
        envelope: Envelope,
        raw: Option<&[u8]>,
        out: &mut Out,
    ) -> Result<(), SendError> {
        let envelope = self.sign_for_origination(envelope)?;
        self.seen.record(&envelope.id);
        let peers: Vec<String> = self.peers.keys().cloned().collect();
        let targets = mesh::forward_targets(
            &envelope,
            None,
            &self.identity.device_id,
            peers.iter().map(String::as_str),
        );
        if targets.is_empty() {
            return Err(SendError::NotConnected);
        }
        let mut last_err = None;
        for target in &targets {
            if let Err(e) = self.send_envelope_to(target, &envelope, raw, out) {
                last_err = Some(e);
            }
        }
        last_err.map_or(Ok(()), Err)
    }

    fn sign_for_origination(&self, envelope: Envelope) -> Result<Envelope, SendError> {
        if envelope.sig.is_some() || envelope.sender_id != self.identity.device_id {
            return Ok(envelope);
        }
        sign::sign(envelope, &self.identity.signing)
            .map_err(|e| SendError::Unsignable(e.to_string()))
    }

    /// Encrypts `envelope` (and an optional raw follow-up, in the same write so nothing interleaves) for one live
    /// peer. Relayed envelopes keep their original signature; local ones are signed here if they are not yet.
    fn send_envelope_to(
        &mut self,
        device_id: &str,
        envelope: &Envelope,
        raw: Option<&[u8]>,
        out: &mut Out,
    ) -> Result<(), SendError> {
        let envelope = self.sign_for_origination(envelope.clone())?;
        let conn = *self.peers.get(device_id).ok_or(SendError::NotConnected)?;
        let c = self.conns.get_mut(&conn).ok_or(SendError::NotConnected)?;
        let transport = c.transport.as_mut().ok_or(SendError::NotConnected)?;
        let ciphertext = transport
            .encrypt(&envelope.encode())
            .map_err(|_| SendError::Encryption)?;
        if ciphertext.len() > MAX_TRANSPORT_FRAME {
            return Err(SendError::TooLarge);
        }
        let mut bytes = frame::encode(&ciphertext);
        if let Some(raw) = raw {
            let raw_ct = transport.encrypt(raw).map_err(|_| SendError::Encryption)?;
            if raw_ct.len() > MAX_TRANSPORT_FRAME {
                return Err(SendError::TooLarge);
            }
            bytes.extend_from_slice(&frame::encode(&raw_ct));
        }
        out.push(Action::Send { conn, bytes });
        Ok(())
    }

    /// Test support: sends `envelope` followed by `raw` to one live peer exactly as given (no hash binding, no
    /// feature gate, no seen-cache entry), so tests can put a deliberately inconsistent raw frame on the wire.
    #[doc(hidden)]
    pub fn send_unchecked_for_tests(
        &mut self,
        device_id: &str,
        envelope: Envelope,
        raw: Option<&[u8]>,
    ) -> Result<Out, SendError> {
        let mut out = Vec::new();
        let envelope = self.sign_for_origination(envelope)?;
        self.send_envelope_to(device_id, &envelope, raw, &mut out)?;
        Ok(out)
    }

    // ---- Time --------------------------------------------------------------------------------------------------

    /// Drive from a timer (once a second is plenty): heartbeats, stale and stuck-connection cleanup, pairing
    /// expiry and reconciliation.
    pub fn tick(&mut self) -> Out {
        let mut out = Vec::new();
        let now = self.env.now_ms();

        if self
            .armed_pairing
            .as_ref()
            .is_some_and(|(_, expires)| now >= *expires)
        {
            self.armed_pairing = None;
        }

        let mut to_close = Vec::new();
        let mut to_ping = Vec::new();
        for (&conn, c) in &self.conns {
            match c.stage {
                Stage::AwaitingHello | Stage::AwaitingAck | Stage::AwaitingProof => {
                    if now - c.stage_since_ms > HANDSHAKE_TIMEOUT_MS
                        && now - c.opened_ms > HANDSHAKE_TIMEOUT_MS
                    {
                        to_close.push(conn);
                    }
                }
                Stage::AwaitingConfirm => {
                    if now - c.stage_since_ms > CONFIRMATION_TIMEOUT_MS {
                        to_close.push(conn);
                    }
                }
                Stage::Live => {
                    if now - c.last_received_ms > HEARTBEAT_TIMEOUT_MS {
                        to_close.push(conn);
                    } else if now - c.last_heartbeat_ms >= HEARTBEAT_INTERVAL_MS {
                        to_ping.push(conn);
                    }
                }
            }
        }
        for conn in to_close {
            self.drop_conn(conn, true, &mut out);
        }
        for conn in to_ping {
            let Some(c) = self.conns.get_mut(&conn) else {
                continue;
            };
            c.last_heartbeat_ms = now;
            let Some(device_id) = c.peer.as_ref().map(|p| p.device_id.clone()) else {
                continue;
            };
            let heartbeat = self.new_envelope("presence.heartbeat").to(&device_id);
            if self
                .send_envelope_to(&device_id, &heartbeat, None, &mut out)
                .is_err()
            {
                self.drop_conn(conn, true, &mut out);
            }
        }

        for due in self.reconciler.tick(now, !self.peers.is_empty()) {
            out.push(Action::Event(Event::ReconcileDue(due)));
        }
        out
    }
}

fn peer_info(claimed: &HandshakeIdentity, noise_public_key: [u8; 32]) -> PeerInfo {
    PeerInfo {
        device_id: claimed.device_id.clone(),
        device_name: claimed.display_name(),
        device_type: claimed.device_type(),
        signing_public_key: claimed.signing_key_bytes(),
        noise_public_key,
    }
}

/// Constant-time comparison of a stored base64 Noise key with the one a peer presented.
fn keys_match(stored_b64: &str, presented: &[u8; 32]) -> bool {
    match B64.decode(stored_b64) {
        Ok(stored) if stored.len() == 32 => bool::from(stored.ct_eq(presented)),
        _ => false,
    }
}

/// Convenience: a payload map from key/value pairs.
pub fn payload<const N: usize>(fields: [(&str, Value); N]) -> Map<String, Value> {
    fields.into_iter().map(|(k, v)| (k.to_owned(), v)).collect()
}

#[allow(dead_code)]
const _: i64 = DEFAULT_TTL;
