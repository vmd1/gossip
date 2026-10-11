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
use crate::features::{self, FeatureSettings};
use crate::limits::{InboundRateLimiter, PendingFrameQueue};
use crate::mesh::{self, SeenCache};
use crate::reconcile::{Due, Reconciler};
use crate::relay::{self, RelayClient, RelayOut, RelayState, RouteTag};
use crate::topic::{Topic, TopicSecret};
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
/// Connection ids at or above this are virtual links through the relay, allocated by the core. A shell must keep
/// the ids it chooses for its own sockets below it.
pub const VIRTUAL_CONN_BASE: ConnId = 1 << 63;
/// How long a trusted peer must have had no live link before this device dials it through the relay.
pub const DEFAULT_LAN_GRACE_MS: i64 = 8_000;
/// The reconcile task the core answers itself (see `reconcile.rs`); it never surfaces as a `ReconcileDue`.
const TOPIC_TASK: &str = "mesh.topic";
/// Delay before a relayed dial to the same device is retried after a link that was up went down.
const RELAY_REDIAL_DELAY_MS: i64 = 3_000;
const RELAY_DIAL_BACKOFF_MAX_MS: i64 = 60_000;

fn is_virtual(conn: ConnId) -> bool {
    conn >= VIRTUAL_CONN_BASE
}

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
    /// Open a WebSocket to the relay at `url`, then report `relay_socket_opened` (or `relay_socket_closed` on failure).
    RelayConnect {
        url: String,
    },
    /// Send this text on the relay socket.
    RelaySendText {
        text: String,
    },
    /// Send this binary message on the relay socket.
    RelaySendBinary {
        bytes: Vec<u8>,
    },
    /// Close the relay socket. The core already considers it gone; do not report its close back.
    RelayClose,
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
    /// This device joined the relay topic; `members` other devices are present.
    RelayJoined {
        members: usize,
    },
    /// The relay connection ended (or was torn down); every relayed link is gone.
    RelayDown,
    /// The relay refused or throttled this device (`upgrade_required`, `denied`, `disabled`, `join_failed`, ...).
    RelayError {
        code: String,
    },
    /// The mesh topic changed: persist `secret` and `epoch` (and feed them to `set_topic` at the next start).
    TopicChanged {
        secret: TopicSecret,
        epoch: u64,
    },
}

/// Coarse relay state for UI.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RelayStatus {
    Disabled,
    /// Enabled but this mesh has no topic yet (no peer has ever connected).
    NoTopic,
    /// Waiting to (re)connect, e.g. in backoff.
    Disconnected,
    /// Socket opening or join in progress.
    Connecting,
    Joined,
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
    /// Set for a virtual link through the relay: the remote device's route tag.
    relay_tag: Option<RouteTag>,
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
            relay_tag: None,
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
    relay: RelayClient,
    topic: Option<Topic>,
    /// Devices this device sent (or received) the current topic secret to/from; used by the revoke-bump rule.
    topic_shared_with: HashSet<String>,
    route_conns: HashMap<RouteTag, ConnId>,
    relay_dialing: HashSet<String>,
    next_virtual: ConnId,
    lan_grace_ms: i64,
    /// When a trusted device was first noticed with no live link.
    link_absent_since: HashMap<String, i64>,
    /// Per device: consecutive failed relayed dials and the earliest next attempt.
    relay_retry: HashMap<String, (u32, i64)>,
    allow_restricted_for_tests: bool,
}

type Out = Vec<Action>;

impl<E: Env> Core<E> {
    pub fn new(
        env: E,
        identity: Identity,
        trust: TrustSnapshot,
        features: FeatureSettings,
    ) -> Self {
        let relay = RelayClient::new(identity.signing.clone());
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
            relay,
            topic: None,
            topic_shared_with: HashSet::new(),
            route_conns: HashMap::new(),
            relay_dialing: HashSet::new(),
            next_virtual: VIRTUAL_CONN_BASE,
            lan_grace_ms: DEFAULT_LAN_GRACE_MS,
            link_absent_since: HashMap::new(),
            relay_retry: HashMap::new(),
            allow_restricted_for_tests: false,
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

    /// Whether the live link to `device_id` goes through the relay. Relayed links refuse `screen.*` and `control.*`.
    pub fn is_relayed(&self, device_id: &str) -> bool {
        self.peers.get(device_id).is_some_and(|c| is_virtual(*c))
    }

    /// Whether a new (LAN) dial to `device_id` would be accepted: not already being dialed, and not live over a
    /// direct link. A relayed link does not count, so the shell keeps trying LAN and the first success replaces it.
    pub fn should_dial(&self, device_id: &str) -> bool {
        !self.dialing.contains(device_id)
            && !self.peers.get(device_id).is_some_and(|c| !is_virtual(*c))
    }

    /// A fresh unsigned envelope from this device: new id, current time, default ttl.
    pub fn new_envelope(&mut self, kind: &str) -> Envelope {
        let id = self.env.new_uuid();
        Envelope::new(id, kind, &self.identity.device_id, self.env.now_ms())
    }

    // ---- Connection lifecycle ---------------------------------------------------------------------------------

    /// An inbound connection was accepted.
    pub fn connection_accepted(&mut self, conn: ConnId) -> Result<Out, DialError> {
        if self.conns.contains_key(&conn) || is_virtual(conn) {
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
        if is_virtual(conn) {
            return Err(DialError::DuplicateConnection);
        }
        self.dial_inner(conn, target, remote_static, pairing, None)
    }

    fn dial_inner(
        &mut self,
        conn: ConnId,
        target: &str,
        remote_static: [u8; 32],
        pairing: Option<PairingIntent>,
        relay_tag: Option<RouteTag>,
    ) -> Result<Out, DialError> {
        if self.conns.contains_key(&conn) {
            return Err(DialError::DuplicateConnection);
        }
        // A direct dial may replace a relayed link; nothing replaces a direct link, and a relayed dial needs none.
        let blocked = match (self.peers.get(target), relay_tag) {
            (Some(existing), None) => !is_virtual(*existing),
            (Some(_), Some(_)) => true,
            (None, _) => false,
        };
        if blocked {
            return Err(DialError::AlreadyConnected);
        }
        let set = if relay_tag.is_some() {
            &mut self.relay_dialing
        } else {
            &mut self.dialing
        };
        if !set.insert(target.to_owned()) {
            return Err(DialError::AlreadyDialing);
        }
        let now = self.env.now_ms();
        let mut c = Conn::new(Role::Initiator, Stage::AwaitingAck, now);
        c.relay_tag = relay_tag;
        c.dial_target = Some(target.to_owned());
        c.pairing_intent = pairing.is_some();
        let identity = self.identity.handshake_identity(pairing.map(|p| p.token));
        let mut hs = Handshake::initiator(&self.identity.noise, remote_static, &[]);
        let ephemeral = self.env.random_array::<32>();
        let msg1 = match hs.write_message1(&identity.encode(), ephemeral) {
            Ok(m) => m,
            Err(e) => {
                self.release_dial(target, relay_tag.is_some());
                return Err(DialError::Handshake(e));
            }
        };
        c.handshake = Some(hs);
        self.conns.insert(conn, c);
        if let Some(tag) = relay_tag {
            self.route_conns.insert(tag, conn);
        }
        let id = self.env.new_uuid();
        let hello = handshake::handshake_envelope(
            handshake::HELLO,
            id,
            &self.identity.device_id,
            None,
            now,
            &msg1,
        );
        let mut out = Vec::new();
        self.emit_send(conn, frame::encode(&hello.encode()), &mut out);
        Ok(out)
    }

    fn release_dial(&mut self, target: &str, relayed: bool) {
        if relayed {
            self.relay_dialing.remove(target);
        } else {
            self.dialing.remove(target);
        }
    }

    /// Queues `bytes` (already length-framed) for a connection: a plain `Send` for a shell socket, relay frames for
    /// a virtual link.
    fn emit_send(&self, conn: ConnId, bytes: Vec<u8>, out: &mut Out) {
        if !is_virtual(conn) {
            out.push(Action::Send { conn, bytes });
            return;
        }
        let Some(tag) = self.conns.get(&conn).and_then(|c| c.relay_tag) else {
            return;
        };
        if !self.relay.is_joined() {
            return;
        }
        for frame in self.relay.frames_for(&tag, &bytes) {
            out.push(Action::RelaySendBinary { bytes: frame });
        }
    }

    /// Virtual links have no socket for the shell to close.
    fn emit_close(conn: ConnId, out: &mut Out) {
        if !is_virtual(conn) {
            out.push(Action::Close { conn });
        }
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
        let Some(c) = self.remove_conn_entry(conn) else {
            return;
        };
        if c.stage == Stage::AwaitingConfirm {
            self.prompt_active = false;
            out.push(Action::Event(Event::PairingPromptCancelled { conn }));
        }
        if let Some(target) = &c.dial_target {
            self.release_dial(target, c.relay_tag.is_some());
            if c.relay_tag.is_some() {
                self.note_relay_dial_ended(target, c.stage == Stage::Live);
            }
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
            Self::emit_close(conn, out);
        }
    }

    /// Removes a connection from the tables (not an event source: callers emit what follows).
    fn remove_conn_entry(&mut self, conn: ConnId) -> Option<Conn> {
        let c = self.conns.remove(&conn)?;
        if let Some(tag) = c.relay_tag {
            if self.route_conns.get(&tag) == Some(&conn) {
                self.route_conns.remove(&tag);
            }
        }
        Some(c)
    }

    /// A relayed dial ended: back off before the next one so a flapping link cannot cause a dial storm.
    fn note_relay_dial_ended(&mut self, target: &str, was_live: bool) {
        let now = self.env.now_ms();
        let entry = self.relay_retry.entry(target.to_owned()).or_insert((0, 0));
        if was_live {
            *entry = (0, now + RELAY_REDIAL_DELAY_MS);
        } else {
            let wait = (5_000i64 << entry.0.min(8)).min(RELAY_DIAL_BACKOFF_MAX_MS);
            *entry = (entry.0 + 1, now + wait);
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
            self.emit_send(conn, frame::encode(&ack.encode()), out);
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
        // started a pairing itself. Either way only one prompt may be open. Pairing never happens over the relay.
        if self.conns.get(&conn).is_some_and(|c| c.relay_tag.is_some()) {
            return self.drop_conn(conn, true, out);
        }
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
        let Some(c) = self.conns.get(&conn) else {
            return;
        };
        let Some(peer) = c.peer.clone() else { return };
        // LAN first: a relayed link never displaces a direct one (the shell would never see a flap, so just forget it).
        if c.relay_tag.is_some()
            && self
                .peers
                .get(&peer.device_id)
                .is_some_and(|e| !is_virtual(*e))
        {
            return self.drop_conn(conn, false, out);
        }
        let Some(c) = self.conns.get_mut(&conn) else {
            return;
        };
        c.stage = Stage::Live;
        c.stage_since_ms = now;
        c.last_received_ms = now;
        c.last_heartbeat_ms = now;
        let relayed = c.relay_tag.is_some();
        if let Some(target) = c.dial_target.clone() {
            self.release_dial(&target, relayed);
        }
        self.link_absent_since.remove(&peer.device_id);
        if relayed {
            self.relay_retry.remove(&peer.device_id);
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
                if let Some(old) = self.remove_conn_entry(stale) {
                    if let Some(t) = &old.dial_target {
                        self.release_dial(t, old.relay_tag.is_some());
                    }
                }
                Self::emit_close(stale, out);
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
        // The mesh topic is the core's own reconcile task: the first device with a peer mints it, and every fresh
        // connect resends the current one.
        if !self.ensure_topic(out) {
            self.send_topic_to(&peer.device_id, out);
        }
        for due in self.reconciler.on_peer_connected(&peer.device_id) {
            if due.task != TOPIC_TASK {
                out.push(Action::Event(Event::ReconcileDue(due)));
            }
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
            return self.finish_raw(conn, pending, plaintext, out);
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
            self.deliver(conn, &envelope, None, out);
        }
        for target in &routing.forward_to {
            let forwarded = envelope.with_forward_ttl(routing.forward_ttl);
            let _ = self.send_envelope_to(target, &forwarded, None, out);
        }
    }

    fn finish_raw(&mut self, conn: ConnId, pending: RawPending, raw: Vec<u8>, out: &mut Out) {
        if pending.discard {
            return;
        }
        // The raw frame is outside the signature; the signed payload carries its hash.
        if !pending.envelope.raw_frame_matches(&raw) {
            return;
        }
        let ttl = pending.envelope.ttl - 1;
        if pending.deliver {
            self.deliver(conn, &pending.envelope, Some(raw.clone()), out);
        }
        for target in &pending.forward_to {
            let forwarded = pending.envelope.with_forward_ttl(ttl);
            let _ = self.send_envelope_to(target, &forwarded, Some(&raw), out);
        }
    }

    /// Handles the infrastructure types itself; everything else goes to the feature handlers.
    fn deliver(&mut self, conn: ConnId, envelope: &Envelope, raw: Option<Vec<u8>>, out: &mut Out) {
        // Bulk and latency-sensitive features never run over the relay, whatever the sender claims.
        if is_virtual(conn) && features::is_relay_restricted(&envelope.kind) {
            return;
        }
        match envelope.kind.as_str() {
            "trust.roster_update" => return self.handle_roster_update(envelope, out),
            "trust.revoke" => return self.handle_revoke(envelope, out),
            "mesh.topic" => return self.handle_mesh_topic(conn, envelope, out),
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
        let named = envelope
            .payload
            .get("deviceId")
            .and_then(Value::as_str)
            .map(str::to_owned);
        let already_revoked = named
            .as_deref()
            .is_some_and(|d| self.trust.revoked_at(d).is_some());
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
        // The revoked device may know the topic secret: move the mesh to a fresh one it never gets. Only the first
        // application counts, so a duplicate or resent revoke is a no-op.
        if !already_revoked {
            self.bump_topic(out);
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
        let already_revoked = self.trust.revoked_at(device_id).is_some();
        self.trust.revoke(device_id, now);
        out.push(Action::Event(Event::TrustChanged(self.trust.snapshot())));
        if let Some(conn) = self.peers.get(device_id).copied() {
            self.drop_conn(conn, true, &mut out);
        }
        if !already_revoked {
            self.bump_topic(&mut out);
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
        if is_virtual(conn)
            && features::is_relay_restricted(&envelope.kind)
            && !self.allow_restricted_for_tests
        {
            return Err(SendError::NotConnected);
        }
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
        self.emit_send(conn, bytes, out);
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
        // Also lets tests put a relay-restricted kind on a relayed link, to check the receiver refuses it.
        self.allow_restricted_for_tests = true;
        let sent = self.send_envelope_to(device_id, &envelope, raw, &mut out);
        self.allow_restricted_for_tests = false;
        sent?;
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

        let relay_outs = self.relay.tick(now, &mut self.env);
        self.apply_relay(relay_outs, &mut out);
        self.relay_poll(&mut out);

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
            if due.task == TOPIC_TASK {
                self.resend_topic_to_all(&mut out);
            } else {
                out.push(Action::Event(Event::ReconcileDue(due)));
            }
        }
        out
    }

    // ---- Relay -------------------------------------------------------------------------------------------------

    /// Turns the relay on or off. `origin` is the relay's address (`wss://host`, also accepted with a trailing
    /// `/connect`); it is signed into joins, so it must be exactly what the relay is configured with. Never gossiped.
    pub fn relay_configure(&mut self, enabled: bool, origin: &str) -> Out {
        let mut out = Vec::new();
        let now = self.env.now_ms();
        let outs = self.relay.configure(enabled, origin, now);
        self.apply_relay(outs, &mut out);
        self.relay_poll(&mut out);
        out
    }

    /// How long a trusted peer must have had no live link before it is dialed through the relay (default 8 s).
    pub fn set_lan_grace_ms(&mut self, ms: i64) {
        self.lan_grace_ms = ms.max(0);
    }

    pub fn relay_status(&self) -> RelayStatus {
        if !self.relay.is_enabled() {
            return RelayStatus::Disabled;
        }
        if !self.relay.has_topic() {
            return RelayStatus::NoTopic;
        }
        match self.relay.state() {
            RelayState::Disconnected => RelayStatus::Disconnected,
            RelayState::Joined => RelayStatus::Joined,
            _ => RelayStatus::Connecting,
        }
    }

    /// The relay WebSocket opened (after `RelayConnect`).
    pub fn relay_socket_opened(&mut self) -> Out {
        let now = self.env.now_ms();
        let outs = self.relay.socket_opened(now);
        let mut out = Vec::new();
        self.apply_relay(outs, &mut out);
        out
    }

    /// The relay WebSocket closed or failed to open, without the core having asked (a `RelayClose` needs no report).
    pub fn relay_socket_closed(&mut self) -> Out {
        let now = self.env.now_ms();
        let outs = self.relay.socket_closed(now, &mut self.env);
        let mut out = Vec::new();
        self.apply_relay(outs, &mut out);
        out
    }

    /// A text message arrived on the relay socket.
    pub fn relay_text_received(&mut self, text: &str) -> Out {
        let now = self.env.now_ms();
        let outs = self.relay.text_received(now, &mut self.env, text);
        let mut out = Vec::new();
        self.apply_relay(outs, &mut out);
        self.relay_poll(&mut out);
        out
    }

    /// A binary message arrived on the relay socket.
    pub fn relay_binary_received(&mut self, bytes: &[u8]) -> Out {
        let outs = self.relay.binary_received(bytes);
        let mut out = Vec::new();
        self.apply_relay(outs, &mut out);
        out
    }

    fn apply_relay(&mut self, outs: Vec<RelayOut>, out: &mut Out) {
        for o in outs {
            match o {
                RelayOut::Connect { url } => out.push(Action::RelayConnect { url }),
                RelayOut::SendText(text) => out.push(Action::RelaySendText { text }),
                RelayOut::SendBinary(bytes) => out.push(Action::RelaySendBinary { bytes }),
                RelayOut::Close => out.push(Action::RelayClose),
                RelayOut::Joined { members, .. } => {
                    out.push(Action::Event(Event::RelayJoined {
                        members: members.len(),
                    }));
                }
                // Dialing waits for the LAN grace; `relay_poll` decides.
                RelayOut::PeerSeen(_) => {}
                RelayOut::PeerGone(tag) => {
                    if let Some(conn) = self.route_conns.get(&tag).copied() {
                        self.drop_conn(conn, false, out);
                    }
                }
                RelayOut::Error(code) => out.push(Action::Event(Event::RelayError { code })),
                RelayOut::Deliver { src, payload } => self.relay_deliver(src, payload, out),
                RelayOut::Down => {
                    let virtuals: Vec<ConnId> = self
                        .conns
                        .keys()
                        .copied()
                        .filter(|c| is_virtual(*c))
                        .collect();
                    for conn in virtuals {
                        self.drop_conn(conn, false, out);
                    }
                    out.push(Action::Event(Event::RelayDown));
                }
            }
        }
    }

    /// Connects the relay when allowed and dials peers that need it.
    fn relay_poll(&mut self, out: &mut Out) {
        let now = self.env.now_ms();
        if let Some(connect) = self.relay.begin_connect(now) {
            self.apply_relay(vec![connect], out);
        }
        self.relay_dial_pass(out);
    }

    /// The route tag a trusted device has in the current topic, once its signing key is known.
    fn tag_of(&self, device: &TrustedDevice) -> Option<RouteTag> {
        let topic = self.topic.as_ref()?;
        let key: [u8; 32] = B64
            .decode(device.signing_public_key.as_deref()?)
            .ok()?
            .try_into()
            .ok()?;
        Some(relay::route_tag_for_key(&topic.keys().topic_id, &key))
    }

    fn device_for_tag(&self, tag: &RouteTag) -> Option<String> {
        self.trust
            .devices()
            .iter()
            .find(|d| self.tag_of(d).as_ref() == Some(tag))
            .map(|d| d.device_id.clone())
    }

    /// Frames from a relay member. A tag we have no link for starts a responder link, but only for a trusted device
    /// with no direct link; everything else is dropped.
    fn relay_deliver(&mut self, src: RouteTag, payload: Vec<u8>, out: &mut Out) {
        let conn = match self.route_conns.get(&src).copied() {
            Some(conn) => conn,
            None => {
                let Some(device) = self.device_for_tag(&src) else {
                    return;
                };
                if self.peers.get(&device).is_some_and(|c| !is_virtual(*c)) {
                    return;
                }
                let conn = self.alloc_virtual();
                let now = self.env.now_ms();
                let mut c = Conn::new(Role::Responder, Stage::AwaitingHello, now);
                c.handshake = Some(Handshake::responder(&self.identity.noise, &[]));
                c.relay_tag = Some(src);
                self.conns.insert(conn, c);
                self.route_conns.insert(src, conn);
                conn
            }
        };
        let more = self.bytes_received(conn, &payload);
        out.extend(more);
    }

    fn alloc_virtual(&mut self) -> ConnId {
        let id = self.next_virtual;
        self.next_virtual = if id == ConnId::MAX {
            VIRTUAL_CONN_BASE
        } else {
            id + 1
        };
        id
    }

    /// LAN first: dial a trusted peer over the relay only when it is present on the relay, has had no live link for
    /// the grace period, and this device has the lower id (so exactly one side initiates).
    fn relay_dial_pass(&mut self, out: &mut Out) {
        if !self.relay.is_joined() {
            self.link_absent_since.clear();
            return;
        }
        let now = self.env.now_ms();
        let mut to_dial = Vec::new();
        for d in self.trust.devices() {
            if self.trust.is_provisional(&d.device_id) || d.device_id == self.identity.device_id {
                continue;
            }
            let Some(tag) = self.tag_of(d) else { continue };
            if self.peers.contains_key(&d.device_id) {
                self.link_absent_since.remove(&d.device_id);
                continue;
            }
            if !self.relay.members().contains(&tag) {
                continue;
            }
            let since = *self
                .link_absent_since
                .entry(d.device_id.clone())
                .or_insert(now);
            if now - since < self.lan_grace_ms
                || self.identity.device_id > d.device_id
                || self.dialing.contains(&d.device_id)
                || self.relay_dialing.contains(&d.device_id)
                || self.route_conns.contains_key(&tag)
                || self
                    .relay_retry
                    .get(&d.device_id)
                    .is_some_and(|(_, at)| now < *at)
            {
                continue;
            }
            let Some(key) = B64
                .decode(&d.public_key)
                .ok()
                .and_then(|k| <[u8; 32]>::try_from(k).ok())
            else {
                continue;
            };
            to_dial.push((d.device_id.clone(), key, tag));
        }
        for (device, key, tag) in to_dial {
            let conn = self.alloc_virtual();
            if let Ok(actions) = self.dial_inner(conn, &device, key, None, Some(tag)) {
                out.extend(actions);
            }
        }
    }

    // ---- Mesh topic --------------------------------------------------------------------------------------------

    /// Loads the persisted topic at startup (no event: the shell already has it).
    pub fn set_topic(&mut self, secret: [u8; 32], epoch: u64) -> Out {
        let mut out = Vec::new();
        self.topic = Some(Topic::new(secret, epoch));
        self.topic_shared_with.clear();
        self.sync_relay_topic(&mut out);
        out
    }

    pub fn topic_epoch(&self) -> Option<u64> {
        self.topic.as_ref().map(|t| t.epoch)
    }

    /// The public rendezvous name of the current topic (what the relay sees), for comparing meshes without
    /// exposing the secret.
    pub fn topic_id(&self) -> Option<[u8; 32]> {
        self.topic.as_ref().map(|t| t.keys().topic_id)
    }

    fn sync_relay_topic(&mut self, out: &mut Out) {
        let now = self.env.now_ms();
        let keys = self.topic.as_ref().map(Topic::keys);
        let outs = self.relay.set_topic(keys, now);
        self.apply_relay(outs, out);
        self.relay_poll(out);
    }

    /// The topic changed: persist it, rejoin the relay under it and hand it to every connected peer except
    /// `except` (the device it came from).
    fn topic_changed(&mut self, except: Option<&str>, out: &mut Out) {
        let Some(topic) = &self.topic else { return };
        out.push(Action::Event(Event::TopicChanged {
            secret: TopicSecret::new(*topic.secret.expose()),
            epoch: topic.epoch,
        }));
        self.sync_relay_topic(out);
        let peers: Vec<String> = self
            .peers
            .keys()
            .filter(|p| Some(p.as_str()) != except)
            .cloned()
            .collect();
        for p in peers {
            self.send_topic_to(&p, out);
        }
    }

    /// The first device with a trusted peer mints the topic (random secret, epoch 1). Returns whether it did.
    fn ensure_topic(&mut self, out: &mut Out) -> bool {
        if self.topic.is_some()
            || !self
                .trust
                .devices()
                .iter()
                .any(|d| !self.trust.is_provisional(&d.device_id))
        {
            return false;
        }
        let secret = self.env.random_array::<32>();
        self.topic = Some(Topic::new(secret, 1));
        self.topic_shared_with.clear();
        self.topic_changed(None, out);
        true
    }

    /// Moves the mesh to a fresh secret at the next epoch, which only non-revoked devices are given.
    fn bump_topic(&mut self, out: &mut Out) {
        let Some(epoch) = self.topic.as_ref().map(|t| t.epoch) else {
            return;
        };
        let secret = self.env.random_array::<32>();
        self.topic = Some(Topic::new(secret, epoch.saturating_add(1)));
        self.topic_shared_with.clear();
        self.topic_changed(None, out);
    }

    /// Sends the current topic to one connected, trusted, non-revoked peer (targeted, ttl 0: never relayed on).
    fn send_topic_to(&mut self, device_id: &str, out: &mut Out) {
        let Some(topic) = &self.topic else { return };
        if !self.peers.contains_key(device_id)
            || !self.trust.is_trusted(device_id)
            || self.trust.revoked_at(device_id).is_some()
        {
            return;
        }
        let payload = topic.payload();
        let envelope = self
            .new_envelope("mesh.topic")
            .to(device_id)
            .with_ttl(0)
            .with_payload(payload);
        if self
            .send_envelope_to(device_id, &envelope, None, out)
            .is_ok()
        {
            self.topic_shared_with.insert(device_id.to_owned());
        }
    }

    fn resend_topic_to_all(&mut self, out: &mut Out) {
        let peers: Vec<String> = self.peers.keys().cloned().collect();
        for p in peers {
            self.send_topic_to(&p, out);
        }
    }

    /// `mesh.topic` from a directly connected peer. Idempotent: only a strictly newer topic changes anything.
    fn handle_mesh_topic(&mut self, conn: ConnId, envelope: &Envelope, out: &mut Out) {
        let from = envelope.sender_id.as_str();
        let direct = self
            .conns
            .get(&conn)
            .and_then(|c| c.peer.as_ref())
            .is_some_and(|p| p.device_id == from);
        if !direct
            || envelope.broadcast
            || envelope.recipient_id.as_deref() != Some(self.identity.device_id.as_str())
            || !self.trust.is_trusted(from)
            || self.trust.revoked_at(from).is_some()
        {
            return;
        }
        let Some(incoming) = Topic::from_payload(&envelope.payload) else {
            return;
        };
        let ordering = self.topic.as_ref().map(|cur| incoming.rank_cmp(cur));
        match ordering {
            None | Some(std::cmp::Ordering::Greater) => {
                self.topic = Some(incoming);
                self.topic_shared_with.clear();
                self.topic_shared_with.insert(from.to_owned());
                self.topic_changed(Some(from), out);
                // Adopting a secret a revoked device also holds hands it the new mesh: bump past it.
                if self
                    .topic_shared_with
                    .iter()
                    .any(|d| self.trust.revoked_at(d).is_some())
                {
                    self.bump_topic(out);
                }
            }
            Some(std::cmp::Ordering::Equal) => {
                self.topic_shared_with.insert(from.to_owned());
            }
            // The sender is behind: tell it ours so it converges without waiting for the periodic resync.
            Some(std::cmp::Ordering::Less) => self.send_topic_to(from, out),
        }
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
