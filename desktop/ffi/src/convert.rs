//! Conversions between core types and the flat records the foreign languages see.

use gossip_core::engine::{self, PeerInfo as CorePeer};
use gossip_core::wire::envelope::Envelope as CoreEnvelope;
use serde_json::{Map, Value};

use crate::error::GossipError;

/// `kind` is the wire `type` field (renamed because `type` is a keyword in both target languages).
#[derive(Debug, Clone, uniffi::Record)]
pub struct Envelope {
    pub v: u32,
    pub id: String,
    pub kind: String,
    pub sender_id: String,
    pub recipient_id: Option<String>,
    pub broadcast: bool,
    pub ttl: i64,
    pub has_raw_followup: bool,
    pub ts: i64,
    /// The payload object as JSON text.
    pub payload_json: String,
    pub sig: Option<String>,
}

impl From<CoreEnvelope> for Envelope {
    fn from(e: CoreEnvelope) -> Self {
        Self {
            v: e.v,
            id: e.id,
            kind: e.kind,
            sender_id: e.sender_id,
            recipient_id: e.recipient_id,
            broadcast: e.broadcast,
            ttl: e.ttl,
            has_raw_followup: e.has_raw_followup,
            ts: e.ts,
            payload_json: Value::Object(e.payload).to_string(),
            sig: e.sig,
        }
    }
}

impl TryFrom<Envelope> for CoreEnvelope {
    type Error = GossipError;

    fn try_from(e: Envelope) -> Result<Self, GossipError> {
        Ok(Self {
            v: e.v,
            id: e.id,
            kind: e.kind,
            sender_id: e.sender_id,
            recipient_id: e.recipient_id,
            broadcast: e.broadcast,
            ttl: e.ttl,
            has_raw_followup: e.has_raw_followup,
            ts: e.ts,
            payload: parse_object(&e.payload_json)?,
            sig: e.sig,
        })
    }
}

pub(crate) fn parse_object(json: &str) -> Result<Map<String, Value>, GossipError> {
    match serde_json::from_str::<Value>(json) {
        Ok(Value::Object(m)) => Ok(m),
        Ok(_) => Err(GossipError::invalid("payload must be a JSON object")),
        Err(e) => Err(GossipError::invalid(format!(
            "payload is not valid JSON: {e}"
        ))),
    }
}

pub(crate) fn object_json(m: Map<String, Value>) -> String {
    Value::Object(m).to_string()
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct PeerInfo {
    pub device_id: String,
    pub device_name: String,
    /// "mac", "android-phone", "android-tablet", "windows", "linux" or an unknown string.
    pub device_type: String,
    /// Raw Ed25519 public key (32 bytes).
    pub signing_public_key: Vec<u8>,
    /// Raw X25519 Noise static public key (32 bytes).
    pub noise_public_key: Vec<u8>,
}

impl From<CorePeer> for PeerInfo {
    fn from(p: CorePeer) -> Self {
        Self {
            device_id: p.device_id,
            device_name: p.device_name,
            device_type: p.device_type.as_str().to_owned(),
            signing_public_key: p.signing_public_key.to_vec(),
            noise_public_key: p.noise_public_key.to_vec(),
        }
    }
}

/// What the shell must do. Returned from every input method of [`crate::engine::GossipCore`].
///
/// No `Debug`: `TopicChanged` carries the mesh topic secret, which must not end up in logs.
#[derive(Clone, uniffi::Enum)]
pub enum Action {
    /// Write these bytes (already length-framed) to the connection.
    Send {
        conn: u64,
        bytes: Vec<u8>,
    },
    /// Close the connection. The core has already forgotten it.
    Close {
        conn: u64,
    },
    /// A peer finished connecting and is live on `conn`. `newly_paired` is true for a just-confirmed pairing.
    PeerConnected {
        conn: u64,
        peer: PeerInfo,
        newly_paired: bool,
    },
    PeerDisconnected {
        device_id: String,
    },
    /// An unknown device needs the user's confirmation; answer with `confirm_pairing`. `code` is the six-digit
    /// comparison code both screens show.
    PairingPrompt {
        conn: u64,
        peer: PeerInfo,
        code: String,
    },
    PairingPromptCancelled {
        conn: u64,
    },
    /// An envelope for a feature handler; `raw` is the follow-up frame when `envelope.has_raw_followup`.
    Deliver {
        envelope: Envelope,
        raw: Option<Vec<u8>>,
    },
    /// A validated message from this device arrived (even relayed): it is reachable.
    Heard {
        device_id: String,
    },
    /// The trust roster changed: persist this snapshot (JSON).
    TrustChanged {
        snapshot_json: String,
    },
    DeviceRevoked {
        device_id: String,
    },
    /// A reconciliation resend is due. `peer` is set for the on-connect send to one peer, `None` for the periodic
    /// broadcast resync.
    ReconcileDue {
        task: String,
        peer: Option<String>,
    },
    /// Open a WebSocket to the relay at `url`, then call `relay_socket_opened` (or `relay_socket_closed` if it fails).
    RelayConnect {
        url: String,
    },
    /// Send this text message on the relay socket.
    RelaySendText {
        text: String,
    },
    /// Send this binary message on the relay socket.
    RelaySendBinary {
        bytes: Vec<u8>,
    },
    /// Close the relay socket. The core already considers it gone: do not report its close back.
    RelayClose,
    /// Joined the relay topic; `members` other devices are present.
    RelayJoined {
        members: u32,
    },
    /// The relay connection ended; every relayed link is gone.
    RelayDown,
    /// The relay refused or throttled this device: "upgrade_required", "denied", "disabled", "join_failed",
    /// "rate_limited", ... (UI hint only; the core backs off by itself).
    RelayError {
        code: String,
    },
    /// The mesh topic changed: persist `secret` (32 bytes) and `epoch` in secure storage and pass them to
    /// `set_topic` at the next start. Never log the secret.
    TopicChanged {
        secret: Vec<u8>,
        epoch: u64,
    },
}

pub(crate) fn actions(list: Vec<engine::Action>) -> Vec<Action> {
    list.into_iter().map(Action::from).collect()
}

impl From<engine::Action> for Action {
    fn from(a: engine::Action) -> Self {
        use engine::{Action as A, Event as E};
        match a {
            A::Send { conn, bytes } => Action::Send { conn, bytes },
            A::Close { conn } => Action::Close { conn },
            A::Event(e) => match e {
                E::PeerConnected {
                    conn,
                    peer,
                    newly_paired,
                } => Action::PeerConnected {
                    conn,
                    peer: peer.into(),
                    newly_paired,
                },
                E::PeerDisconnected { device_id } => Action::PeerDisconnected { device_id },
                E::PairingPrompt { conn, peer, code } => Action::PairingPrompt {
                    conn,
                    peer: peer.into(),
                    code,
                },
                E::PairingPromptCancelled { conn } => Action::PairingPromptCancelled { conn },
                E::Deliver { envelope, raw } => Action::Deliver {
                    envelope: envelope.into(),
                    raw,
                },
                E::Heard { device_id } => Action::Heard { device_id },
                E::TrustChanged(snapshot) => Action::TrustChanged {
                    snapshot_json: serde_json::to_string(&snapshot).expect("snapshot serialises"),
                },
                E::DeviceRevoked { device_id } => Action::DeviceRevoked { device_id },
                E::ReconcileDue(due) => Action::ReconcileDue {
                    task: due.task.to_owned(),
                    peer: due.peer,
                },
                E::RelayJoined { members } => Action::RelayJoined {
                    members: u32::try_from(members).unwrap_or(u32::MAX),
                },
                E::RelayDown => Action::RelayDown,
                E::RelayError { code } => Action::RelayError { code },
                E::TopicChanged { secret, epoch } => Action::TopicChanged {
                    secret: secret.expose().to_vec(),
                    epoch,
                },
            },
            A::RelayConnect { url } => Action::RelayConnect { url },
            A::RelaySendText { text } => Action::RelaySendText { text },
            A::RelaySendBinary { bytes } => Action::RelaySendBinary { bytes },
            A::RelayClose => Action::RelayClose,
        }
    }
}
