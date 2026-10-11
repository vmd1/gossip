//! The relay client: pure helpers that match `schema/conformance/relay-vectors.json` byte for byte, and the sans-IO
//! [`RelayClient`] state machine that joins a topic on a relay (`relay/`, `docs/plans/relay.md`).
//!
//! The shell owns exactly one WebSocket. It reports what happened (`socket_opened`, text and binary messages,
//! `socket_closed`) and executes the [`RelayOut`] values that come back. Nothing here reads a clock or an RNG: time
//! is passed in, and the only randomness (reconnect jitter) comes from an [`Env`].
//!
//! The relay is an untrusted router. Everything it forwards is the same `[len][Noise ciphertext]` stream the LAN
//! transport carries, wrapped in a `dstTag(8) || srcTag(8) || payload` header, so this module never sees plaintext
//! and never assumes one WebSocket message equals one frame (the engine's frame decoder reassembles per peer).

use std::collections::BTreeSet;
use std::fmt;

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use ed25519_dalek::{Signer, SigningKey};
use hmac::{Hmac, Mac};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use zeroize::{Zeroize, ZeroizeOnDrop};

use crate::env::Env;

type HmacSha256 = Hmac<Sha256>;

/// An 8-byte per-topic route tag.
pub type RouteTag = [u8; TAG_LEN];

pub const TAG_LEN: usize = 8;
/// `dstTag || srcTag`.
pub const HEADER_LEN: usize = 2 * TAG_LEN;
/// Sent in `relay.join.version`; the relay can refuse clients below its minimum. Matches the 2.0 schema release.
pub const RELAY_CLIENT_VERSION: &str = "2.0";
/// WebSocket path of a relay (`RELAY_PATH` default).
pub const RELAY_PATH: &str = "/connect";
/// The relay's `maxFrameBytes` default: a 16 MiB payload plus the 16-byte header.
pub const DEFAULT_MAX_FRAME_BYTES: usize = 16 * 1024 * 1024 + HEADER_LEN;

const JOIN_DOMAIN: &str = "gossip-relay-join-v1\n";
const POW_DOMAIN: &str = "gossip-relay-pow-v1";
/// A relay asking for more proof of work than this is refused (it would stall a device for no benefit).
pub const MAX_POW_BITS: u32 = 22;
/// Hash attempts per [`RelayClient::tick`] / message while solving, so a tick never blocks for long.
const POW_SLICE_ITERS: u64 = 1 << 20;
/// Joins sent on one connection (the relay allows 3; PoW errors keep the socket open for a retry).
const MAX_JOIN_ATTEMPTS: u8 = 3;
/// A connection that has not reached `Joined` this long after the attempt began is abandoned.
pub const CONNECT_TIMEOUT_MS: i64 = 20_000;
pub const BACKOFF_BASE_MS: i64 = 2_000;
pub const BACKOFF_MAX_MS: i64 = 300_000;
const MAX_CONTROL_TEXT: usize = 8 * 1024;

// ---- Pure crypto, mirrored by the conformance vectors -----------------------------------------------------------

fn hmac_sha256(key: &[u8], parts: &[&[u8]]) -> [u8; 32] {
    let mut mac = HmacSha256::new_from_slice(key).expect("HMAC accepts any key length");
    for p in parts {
        mac.update(p);
    }
    mac.finalize().into_bytes().into()
}

fn sha256(parts: &[&[u8]]) -> [u8; 32] {
    let mut h = Sha256::new();
    for p in parts {
        h.update(p);
    }
    h.finalize().into()
}

/// `SHA-256(ed25519 public key)`, the relay-visible identity of a device.
pub fn public_key_hash(signing_public_key: &[u8; 32]) -> [u8; 32] {
    sha256(&[signing_public_key])
}

/// `HMAC-SHA256(topicSecret, "gossip-topic" || u64be(epoch))`.
pub fn topic_id(topic_secret: &[u8; 32], epoch: u64) -> [u8; 32] {
    hmac_sha256(topic_secret, &[b"gossip-topic", &epoch.to_be_bytes()])
}

/// `HMAC-SHA256(topicSecret, "gossip-topic-auth" || u64be(epoch))`.
pub fn topic_auth_key(topic_secret: &[u8; 32], epoch: u64) -> [u8; 32] {
    hmac_sha256(topic_secret, &[b"gossip-topic-auth", &epoch.to_be_bytes()])
}

/// `SHA-256(topicAuthKey)`: what the relay stores for a topic and what every join carries.
pub fn topic_verifier(auth_key: &[u8; 32]) -> [u8; 32] {
    sha256(&[auth_key])
}

/// `SHA-256(topicId || publicKeyHash)[0..8]`.
pub fn route_tag(topic_id: &[u8; 32], public_key_hash: &[u8; 32]) -> RouteTag {
    let d = sha256(&[topic_id, public_key_hash]);
    d[..TAG_LEN].try_into().expect("8 bytes")
}

/// The route tag a device with this Ed25519 key has in a topic.
pub fn route_tag_for_key(topic_id: &[u8; 32], signing_public_key: &[u8; 32]) -> RouteTag {
    route_tag(topic_id, &public_key_hash(signing_public_key))
}

/// `utf8("gossip-relay-join-v1\n") || utf8(origin) || 0x0A || nonce || topicId`.
pub fn join_signing_input(origin: &str, nonce: &[u8; 32], topic_id: &[u8; 32]) -> Vec<u8> {
    let mut v = Vec::with_capacity(JOIN_DOMAIN.len() + origin.len() + 1 + 64);
    v.extend_from_slice(JOIN_DOMAIN.as_bytes());
    v.extend_from_slice(origin.as_bytes());
    v.push(0x0a);
    v.extend_from_slice(nonce);
    v.extend_from_slice(topic_id);
    v
}

pub fn join_signature(
    signing: &SigningKey,
    origin: &str,
    nonce: &[u8; 32],
    topic_id: &[u8; 32],
) -> [u8; 64] {
    signing
        .sign(&join_signing_input(origin, nonce, topic_id))
        .to_bytes()
}

/// `HMAC-SHA256(key = verifier, msg = nonce)`.
pub fn join_proof(verifier: &[u8; 32], nonce: &[u8; 32]) -> [u8; 32] {
    hmac_sha256(verifier, &[nonce])
}

pub fn pow_digest(key_hash: &[u8; 32], nonce: &[u8; 32], pow: &[u8; 8]) -> [u8; 32] {
    sha256(&[POW_DOMAIN.as_bytes(), key_hash, nonce, pow])
}

pub fn leading_zero_bits(digest: &[u8]) -> u32 {
    let mut bits = 0;
    for &b in digest {
        if b == 0 {
            bits += 8;
        } else {
            bits += b.leading_zeros();
            break;
        }
    }
    bits
}

pub fn check_pow(key_hash: &[u8; 32], nonce: &[u8; 32], pow: &[u8; 8], bits: u32) -> bool {
    bits == 0 || leading_zero_bits(&pow_digest(key_hash, nonce, pow)) >= bits
}

/// Tries counters `start..start + iters` and returns the first (smallest) that satisfies `bits`; otherwise the
/// counter to resume from. Deterministic, so every implementation finds the same solution.
pub fn solve_pow_slice(
    key_hash: &[u8; 32],
    nonce: &[u8; 32],
    bits: u32,
    start: u64,
    iters: u64,
) -> Result<[u8; 8], u64> {
    if bits == 0 {
        return Ok([0; 8]);
    }
    let mut prefix = Sha256::new();
    prefix.update(POW_DOMAIN.as_bytes());
    prefix.update(key_hash);
    prefix.update(nonce);
    let end = start.saturating_add(iters);
    let mut counter = start;
    while counter < end {
        let pow = counter.to_be_bytes();
        let mut h = prefix.clone();
        h.update(pow);
        if leading_zero_bits(&h.finalize()) >= bits {
            return Ok(pow);
        }
        counter += 1;
    }
    Err(end)
}

/// The smallest counter meeting `bits`, giving up after `2^(bits + 6)` attempts (64 times the expected work) and
/// for any `bits` above [`MAX_POW_BITS`].
pub fn solve_pow(key_hash: &[u8; 32], nonce: &[u8; 32], bits: u32) -> Option<[u8; 8]> {
    if bits > MAX_POW_BITS {
        return None;
    }
    solve_pow_slice(key_hash, nonce, bits, 0, 1u64 << (bits + 6)).ok()
}

/// `dstTag || srcTag || payload`.
pub fn encode_frame(dst: &RouteTag, src: &RouteTag, payload: &[u8]) -> Vec<u8> {
    let mut v = Vec::with_capacity(HEADER_LEN + payload.len());
    v.extend_from_slice(dst);
    v.extend_from_slice(src);
    v.extend_from_slice(payload);
    v
}

/// Splits a relay data frame into `(dst, src, payload)`. `None` unless there is a non-empty payload.
pub fn decode_frame(frame: &[u8]) -> Option<(RouteTag, RouteTag, &[u8])> {
    if frame.len() <= HEADER_LEN {
        return None;
    }
    let dst = frame[..TAG_LEN].try_into().ok()?;
    let src = frame[TAG_LEN..HEADER_LEN].try_into().ok()?;
    Some((dst, src, &frame[HEADER_LEN..]))
}

/// What a join needs from the topic. Derived from the secret; the secret itself never reaches the client.
#[derive(Clone, PartialEq, Eq, Zeroize, ZeroizeOnDrop)]
pub struct TopicKeys {
    pub topic_id: [u8; 32],
    pub verifier: [u8; 32],
}

impl TopicKeys {
    pub fn derive(topic_secret: &[u8; 32], epoch: u64) -> Self {
        Self {
            topic_id: topic_id(topic_secret, epoch),
            verifier: topic_verifier(&topic_auth_key(topic_secret, epoch)),
        }
    }
}

impl fmt::Debug for TopicKeys {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("TopicKeys(<redacted>)")
    }
}

// ---- State machine ----------------------------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RelayState {
    /// No socket. `should_connect` says when the next attempt is allowed.
    Disconnected,
    /// `Connect` was emitted; waiting for `socket_opened`.
    Connecting,
    AwaitingChallenge,
    /// Working through the proof of work the relay asked for.
    Solving,
    /// `relay.join` sent, waiting for `relay.joined`.
    Joining,
    Joined,
}

/// What the shell must do, plus the events the engine consumes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RelayOut {
    /// Open a WebSocket to `url`, then call `socket_opened`.
    Connect {
        url: String,
    },
    SendText(String),
    SendBinary(Vec<u8>),
    /// Close the socket. The client already considers it gone.
    Close,
    Joined {
        route_tag: RouteTag,
        members: Vec<RouteTag>,
    },
    PeerSeen(RouteTag),
    PeerGone(RouteTag),
    /// A relay error code (or a client-side reason such as `pow_too_hard`).
    Error(String),
    /// A relayed data frame from `src` (already authenticated by the relay).
    Deliver {
        src: RouteTag,
        payload: Vec<u8>,
    },
    /// The joined connection is gone: every relayed link is dead.
    Down,
}

pub struct RelayClient {
    signing: SigningKey,
    key_hash: [u8; 32],
    enabled: bool,
    origin: String,
    topic: Option<TopicKeys>,
    state: RelayState,
    state_since_ms: i64,
    nonce: [u8; 32],
    pow_bits: u32,
    pow_next: u64,
    join_attempts: u8,
    own_tag: Option<RouteTag>,
    members: BTreeSet<RouteTag>,
    max_frame: usize,
    fail_count: u32,
    reconnect_at: i64,
}

impl fmt::Debug for RelayClient {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RelayClient")
            .field("enabled", &self.enabled)
            .field("origin", &self.origin)
            .field("state", &self.state)
            .finish_non_exhaustive()
    }
}

/// Splits a user-supplied relay address into the origin that is signed into joins and the WebSocket URL.
/// Accepts `wss://host`, `wss://host/` and `wss://host/connect`; only `ws://` and `wss://` are valid.
pub fn normalize_origin(input: &str) -> Option<(String, String)> {
    let trimmed = input.trim().trim_end_matches('/');
    let origin = trimmed.strip_suffix(RELAY_PATH).unwrap_or(trimmed);
    let rest = origin
        .strip_prefix("wss://")
        .or_else(|| origin.strip_prefix("ws://"))?;
    if rest.is_empty() || rest.contains(char::is_whitespace) || rest.contains(['?', '#']) {
        return None;
    }
    Some((origin.to_owned(), format!("{origin}{RELAY_PATH}")))
}

fn error_floor_ms(code: &str) -> i64 {
    match code {
        // The app is too old, banned or not allowed: retrying soon cannot help.
        "upgrade_required" | "denied" | "unauthorized" => 3_600_000,
        // Operator kill switch: treated as an outage, checked occasionally.
        "disabled" => 600_000,
        "join_failed" | "busy" | "rate_limited" | "limit_exceeded" | "quota_exceeded" => 30_000,
        _ => 0,
    }
}

impl RelayClient {
    pub fn new(signing: SigningKey) -> Self {
        let key_hash = public_key_hash(&signing.verifying_key().to_bytes());
        Self {
            signing,
            key_hash,
            enabled: false,
            origin: String::new(),
            topic: None,
            state: RelayState::Disconnected,
            state_since_ms: 0,
            nonce: [0; 32],
            pow_bits: 0,
            pow_next: 0,
            join_attempts: 0,
            own_tag: None,
            members: BTreeSet::new(),
            max_frame: DEFAULT_MAX_FRAME_BYTES,
            fail_count: 0,
            reconnect_at: 0,
        }
    }

    pub fn state(&self) -> RelayState {
        self.state
    }

    pub fn is_enabled(&self) -> bool {
        self.enabled && !self.origin.is_empty()
    }

    pub fn has_topic(&self) -> bool {
        self.topic.is_some()
    }

    pub fn is_joined(&self) -> bool {
        self.state == RelayState::Joined
    }

    pub fn own_tag(&self) -> Option<RouteTag> {
        self.own_tag
    }

    pub fn members(&self) -> &BTreeSet<RouteTag> {
        &self.members
    }

    pub fn reconnect_at(&self) -> i64 {
        self.reconnect_at
    }

    pub fn connect_url(&self) -> Option<String> {
        normalize_origin(&self.origin).map(|(_, url)| url)
    }

    /// Whether the shell should be told to open a socket now.
    pub fn should_connect(&self, now_ms: i64) -> bool {
        self.is_enabled()
            && self.topic.is_some()
            && self.state == RelayState::Disconnected
            && now_ms >= self.reconnect_at
    }

    /// Marks a connect attempt as started and returns the action for the shell. `None` when not allowed yet.
    pub fn begin_connect(&mut self, now_ms: i64) -> Option<RelayOut> {
        if !self.should_connect(now_ms) {
            return None;
        }
        let url = self.connect_url()?;
        self.state = RelayState::Connecting;
        self.state_since_ms = now_ms;
        Some(RelayOut::Connect { url })
    }

    /// Turns the relay on or off and sets its address (`wss://host`; see [`normalize_origin`]). Any change to a
    /// live connection tears it down; enabling reconnects immediately.
    pub fn configure(&mut self, enabled: bool, origin: &str, now_ms: i64) -> Vec<RelayOut> {
        let new_origin = normalize_origin(origin).map(|(o, _)| o).unwrap_or_default();
        let valid = enabled && !new_origin.is_empty();
        let changed = valid != self.enabled || (valid && new_origin != self.origin);
        self.enabled = valid;
        self.origin = if valid { new_origin } else { String::new() };
        let mut out = Vec::new();
        if changed {
            self.teardown(&mut out);
            self.fail_count = 0;
            self.reconnect_at = now_ms;
        }
        if enabled && !valid {
            out.push(RelayOut::Error("bad_origin".into()));
        }
        out
    }

    /// Sets (or clears) the topic to join. A different topic means a new join: the old connection is dropped.
    pub fn set_topic(&mut self, topic: Option<TopicKeys>, now_ms: i64) -> Vec<RelayOut> {
        let mut out = Vec::new();
        if self.topic != topic {
            self.topic = topic;
            self.teardown(&mut out);
            self.fail_count = 0;
            self.reconnect_at = now_ms;
        }
        out
    }

    /// Leaves whatever connection state exists, telling the shell to close the socket.
    fn teardown(&mut self, out: &mut Vec<RelayOut>) {
        let was = self.state;
        if was != RelayState::Disconnected {
            out.push(RelayOut::Close);
        }
        if was == RelayState::Joined {
            out.push(RelayOut::Down);
        }
        self.reset_connection();
    }

    fn reset_connection(&mut self) {
        self.state = RelayState::Disconnected;
        self.own_tag = None;
        self.members.clear();
        self.join_attempts = 0;
        self.pow_next = 0;
        self.max_frame = DEFAULT_MAX_FRAME_BYTES;
    }

    /// The connection failed or was refused: close it and schedule the next attempt with exponential backoff and
    /// jitter. `floor_ms` is the minimum wait for errors where retrying sooner is pointless.
    fn fail<E: Env>(
        &mut self,
        now_ms: i64,
        env: &mut E,
        floor_ms: i64,
        close: bool,
        out: &mut Vec<RelayOut>,
    ) {
        let was = self.state;
        if was == RelayState::Disconnected {
            return;
        }
        if close {
            out.push(RelayOut::Close);
        }
        if was == RelayState::Joined {
            out.push(RelayOut::Down);
        }
        self.reset_connection();
        self.fail_count = self.fail_count.saturating_add(1);
        let delay = self.backoff_ms(env).max(floor_ms);
        self.reconnect_at = now_ms + delay;
    }

    /// `min(max, base * 2^(n-1))`, then jittered into `[half, full]` so a relay restart does not cause a herd.
    fn backoff_ms<E: Env>(&self, env: &mut E) -> i64 {
        let exp = self.fail_count.saturating_sub(1).min(16);
        let full = (BACKOFF_BASE_MS << exp).min(BACKOFF_MAX_MS);
        let half = full / 2;
        let r = u32::from_be_bytes(env.random_array::<4>()) as i64;
        half + r % (full - half + 1)
    }

    // ---- Shell events ----------------------------------------------------------------------------------------

    pub fn socket_opened(&mut self, now_ms: i64) -> Vec<RelayOut> {
        if self.state == RelayState::Connecting {
            self.state = RelayState::AwaitingChallenge;
            self.state_since_ms = now_ms;
        }
        Vec::new()
    }

    /// The socket closed or failed to open without the client asking for it.
    pub fn socket_closed<E: Env>(&mut self, now_ms: i64, env: &mut E) -> Vec<RelayOut> {
        let mut out = Vec::new();
        self.fail(now_ms, env, 0, false, &mut out);
        out
    }

    pub fn text_received<E: Env>(&mut self, now_ms: i64, env: &mut E, text: &str) -> Vec<RelayOut> {
        let mut out = Vec::new();
        if self.state == RelayState::Disconnected || text.len() > MAX_CONTROL_TEXT {
            return out;
        }
        let Ok(Value::Object(msg)) = serde_json::from_str::<Value>(text) else {
            return out;
        };
        let Some(kind) = msg.get("type").and_then(Value::as_str) else {
            return out;
        };
        match kind {
            "relay.challenge" if self.state == RelayState::AwaitingChallenge => {
                let nonce = msg
                    .get("nonce")
                    .and_then(Value::as_str)
                    .and_then(|s| B64.decode(s).ok())
                    .and_then(|b| <[u8; 32]>::try_from(b).ok());
                let Some(nonce) = nonce else {
                    return self.fail_with(now_ms, env, "bad_challenge");
                };
                self.nonce = nonce;
                self.pow_bits = msg
                    .get("powBits")
                    .and_then(Value::as_u64)
                    .unwrap_or(0)
                    .min(u32::MAX as u64) as u32;
                self.send_join(now_ms, None, &mut out);
            }
            "relay.joined" if self.state == RelayState::Joining => {
                let tag = msg
                    .get("routeTag")
                    .and_then(Value::as_str)
                    .and_then(decode_tag);
                let (Some(tag), Some(topic)) = (tag, self.topic.as_ref()) else {
                    return self.fail_with(now_ms, env, "bad_joined");
                };
                let _ = topic;
                let members: Vec<RouteTag> = msg
                    .get("members")
                    .and_then(Value::as_array)
                    .map(|a| {
                        a.iter()
                            .filter_map(Value::as_str)
                            .filter_map(decode_tag)
                            .filter(|t| *t != tag)
                            .collect()
                    })
                    .unwrap_or_default();
                if let Some(max) = msg
                    .get("limits")
                    .and_then(|l| l.get("maxFrameBytes"))
                    .and_then(Value::as_u64)
                {
                    self.max_frame =
                        (max as usize).clamp(HEADER_LEN + 1024, DEFAULT_MAX_FRAME_BYTES);
                }
                self.state = RelayState::Joined;
                self.state_since_ms = now_ms;
                self.own_tag = Some(tag);
                self.fail_count = 0;
                self.members = members.iter().copied().collect();
                out.push(RelayOut::Joined {
                    route_tag: tag,
                    members: members.clone(),
                });
                out.extend(members.into_iter().map(RelayOut::PeerSeen));
            }
            "relay.peer_joined" | "relay.peer_left" if self.state == RelayState::Joined => {
                let Some(tag) = msg
                    .get("routeTag")
                    .and_then(Value::as_str)
                    .and_then(decode_tag)
                else {
                    return out;
                };
                if Some(tag) == self.own_tag {
                    return out;
                }
                if kind == "relay.peer_joined" {
                    self.members.insert(tag);
                    out.push(RelayOut::PeerSeen(tag));
                } else if self.members.remove(&tag) {
                    out.push(RelayOut::PeerGone(tag));
                }
            }
            "relay.error" => {
                let code = msg
                    .get("code")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown")
                    .chars()
                    .take(32)
                    .collect::<String>();
                self.handle_error(now_ms, env, code, &mut out);
            }
            _ => {}
        }
        out
    }

    fn fail_with<E: Env>(&mut self, now_ms: i64, env: &mut E, code: &str) -> Vec<RelayOut> {
        let mut out = vec![RelayOut::Error(code.to_owned())];
        self.fail(now_ms, env, error_floor_ms(code), true, &mut out);
        out
    }

    fn handle_error<E: Env>(
        &mut self,
        now_ms: i64,
        env: &mut E,
        code: String,
        out: &mut Vec<RelayOut>,
    ) {
        // Throttling of data frames: the connection stays up, only report it.
        if self.state == RelayState::Joined
            && matches!(code.as_str(), "rate_limited" | "quota_exceeded")
        {
            out.push(RelayOut::Error(code));
            return;
        }
        let retryable_pow = matches!(code.as_str(), "pow_required" | "pow_invalid")
            && self.state == RelayState::Joining
            && self.join_attempts < MAX_JOIN_ATTEMPTS;
        if retryable_pow {
            if self.pow_bits == 0 || self.pow_bits > MAX_POW_BITS {
                out.push(RelayOut::Error("pow_too_hard".into()));
                self.fail(now_ms, env, 3_600_000, true, out);
                return;
            }
            self.state = RelayState::Solving;
            self.pow_next = 0;
            self.step_pow(now_ms, out);
            return;
        }
        out.push(RelayOut::Error(code.clone()));
        self.fail(now_ms, env, error_floor_ms(&code), true, out);
    }

    fn step_pow(&mut self, now_ms: i64, out: &mut Vec<RelayOut>) {
        match solve_pow_slice(
            &self.key_hash,
            &self.nonce,
            self.pow_bits,
            self.pow_next,
            POW_SLICE_ITERS,
        ) {
            Ok(pow) => self.send_join(now_ms, Some(pow), out),
            Err(next) => self.pow_next = next,
        }
    }

    fn send_join(&mut self, now_ms: i64, pow: Option<[u8; 8]>, out: &mut Vec<RelayOut>) {
        let Some(topic) = &self.topic else { return };
        let sig = join_signature(&self.signing, &self.origin, &self.nonce, &topic.topic_id);
        let mut msg = json!({
            "type": "relay.join",
            "publicKey": B64.encode(self.signing.verifying_key().to_bytes()),
            "topicId": B64.encode(topic.topic_id),
            "sig": B64.encode(sig),
            "verifier": B64.encode(topic.verifier),
            "proof": B64.encode(join_proof(&topic.verifier, &self.nonce)),
            "version": RELAY_CLIENT_VERSION,
        });
        if let Some(pow) = pow {
            msg["pow"] = Value::String(B64.encode(pow));
        }
        self.join_attempts += 1;
        self.state = RelayState::Joining;
        self.state_since_ms = now_ms;
        out.push(RelayOut::SendText(msg.to_string()));
    }

    /// A binary WebSocket message. Only meaningful once joined.
    pub fn binary_received(&mut self, bytes: &[u8]) -> Vec<RelayOut> {
        if self.state != RelayState::Joined {
            return Vec::new();
        }
        match decode_frame(bytes) {
            Some((_dst, src, payload)) => vec![RelayOut::Deliver {
                src,
                payload: payload.to_vec(),
            }],
            None => Vec::new(),
        }
    }

    /// Timers: proof-of-work slices and the connect/join deadlines. Does not start connections; the engine asks
    /// [`RelayClient::begin_connect`].
    pub fn tick<E: Env>(&mut self, now_ms: i64, env: &mut E) -> Vec<RelayOut> {
        let mut out = Vec::new();
        match self.state {
            RelayState::Solving => {
                if self.pow_next >= 1u64 << (self.pow_bits + 6) {
                    out.push(RelayOut::Error("pow_unsolved".into()));
                    self.fail(now_ms, env, 0, true, &mut out);
                } else {
                    self.step_pow(now_ms, &mut out);
                }
            }
            RelayState::Connecting | RelayState::AwaitingChallenge | RelayState::Joining => {}
            _ => return out,
        }
        if matches!(
            self.state,
            RelayState::Connecting
                | RelayState::AwaitingChallenge
                | RelayState::Joining
                | RelayState::Solving
        ) && now_ms - self.state_since_ms > CONNECT_TIMEOUT_MS
        {
            out.push(RelayOut::Error("timeout".into()));
            self.fail(now_ms, env, 0, true, &mut out);
        }
        out
    }

    /// Wraps `payload` (a slice of a peer's `[len][ciphertext]` stream) for `dst`, splitting only if it exceeds the
    /// relay's frame limit. Empty payloads produce nothing (the relay drops them).
    pub fn frames_for(&self, dst: &RouteTag, payload: &[u8]) -> Vec<Vec<u8>> {
        let src = self.own_tag.unwrap_or([0; TAG_LEN]);
        let chunk = self.max_frame.saturating_sub(HEADER_LEN).max(1);
        payload
            .chunks(chunk)
            .map(|c| encode_frame(dst, &src, c))
            .collect()
    }
}

fn decode_tag(b64: &str) -> Option<RouteTag> {
    B64.decode(b64).ok()?.try_into().ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::env::TestEnv;

    const VECTORS: &str = include_str!("../../../schema/conformance/relay-vectors.json");

    fn vectors() -> Value {
        serde_json::from_str(VECTORS).unwrap()
    }

    fn hex32(v: &Value) -> [u8; 32] {
        hex::decode(v.as_str().unwrap())
            .unwrap()
            .try_into()
            .unwrap()
    }

    fn hex_vec(v: &Value) -> Vec<u8> {
        hex::decode(v.as_str().unwrap()).unwrap()
    }

    fn device(v: &Value, name: &str) -> (SigningKey, Value) {
        let d = v["devices"]
            .as_array()
            .unwrap()
            .iter()
            .find(|d| d["name"] == name)
            .unwrap()
            .clone();
        (SigningKey::from_bytes(&hex32(&d["seedHex"])), d)
    }

    fn secret(v: &Value) -> [u8; 32] {
        hex32(&v["topicSecretHex"])
    }

    #[test]
    fn key_hashes_topics_and_route_tags_match_the_vectors() {
        let v = vectors();
        for name in ["A", "B"] {
            let (sk, d) = device(&v, name);
            let pk = sk.verifying_key().to_bytes();
            assert_eq!(B64.encode(pk), d["publicKey"].as_str().unwrap());
            assert_eq!(public_key_hash(&pk), hex32(&d["publicKeyHashHex"]));
        }
        assert_eq!(public_key_hash_of_empty(), hex32(&v["sha256OfEmptyHex"]));
        for t in v["topics"].as_array().unwrap() {
            let epoch: u64 = t["epoch"].as_str().unwrap().parse().unwrap();
            assert_eq!(epoch.to_be_bytes().to_vec(), hex_vec(&t["epochU64beHex"]));
            let id = topic_id(&secret(&v), epoch);
            assert_eq!(id, hex32(&t["topicIdHex"]));
            let auth = topic_auth_key(&secret(&v), epoch);
            assert_eq!(auth, hex32(&t["topicAuthKeyHex"]));
            assert_eq!(topic_verifier(&auth), hex32(&t["verifierHex"]));
            for (name, field) in [("A", "routeTagAHex"), ("B", "routeTagBHex")] {
                let (sk, _) = device(&v, name);
                let tag = route_tag_for_key(&id, &sk.verifying_key().to_bytes());
                assert_eq!(tag.to_vec(), hex_vec(&t[field]));
            }
        }
    }

    fn public_key_hash_of_empty() -> [u8; 32] {
        sha256(&[])
    }

    #[test]
    fn join_signature_proof_and_pow_match_the_vectors() {
        let v = vectors();
        let j = &v["join"];
        let (sk, _) = device(&v, j["device"].as_str().unwrap());
        let epoch: u64 = j["epoch"].as_str().unwrap().parse().unwrap();
        let keys = TopicKeys::derive(&secret(&v), epoch);
        let nonce = hex32(&j["nonceHex"]);
        let origin = v["relayOrigin"].as_str().unwrap();
        assert_eq!(
            join_signing_input(origin, &nonce, &keys.topic_id),
            hex_vec(&j["signingInputHex"])
        );
        assert_eq!(
            join_signature(&sk, origin, &nonce, &keys.topic_id).to_vec(),
            hex_vec(&j["sigHex"])
        );
        assert_eq!(join_proof(&keys.verifier, &nonce), hex32(&j["proofHex"]));

        let key_hash = public_key_hash(&sk.verifying_key().to_bytes());
        let bits = j["powBits"].as_u64().unwrap() as u32;
        let pow = solve_pow(&key_hash, &nonce, bits).expect("solvable");
        assert_eq!(pow.to_vec(), hex_vec(&j["powHex"]));
        assert_eq!(
            u64::from_be_bytes(pow).to_string(),
            j["powCounter"].as_str().unwrap()
        );
        assert_eq!(
            pow_digest(&key_hash, &nonce, &pow),
            hex32(&j["powDigestHex"])
        );
        assert!(check_pow(&key_hash, &nonce, &pow, bits));
        assert_eq!(
            leading_zero_bits(&pow_digest(&key_hash, &nonce, &pow)),
            j["powLeadingZeroBits"].as_u64().unwrap() as u32
        );
        // One more bit than the digest has must fail the check.
        assert!(!check_pow(&key_hash, &nonce, &pow, 17));
    }

    #[test]
    fn solve_pow_is_bounded() {
        let k = [1u8; 32];
        let n = [2u8; 32];
        assert_eq!(solve_pow(&k, &n, 0), Some([0; 8]));
        assert_eq!(solve_pow(&k, &n, MAX_POW_BITS + 1), None);
        assert_eq!(solve_pow_slice(&k, &n, 40, 0, 1000), Err(1000));
        // Deterministic.
        assert_eq!(solve_pow(&k, &n, 8), solve_pow(&k, &n, 8));
    }

    #[test]
    fn frame_header_matches_the_vectors() {
        let v = vectors();
        let f = &v["frame"];
        let dst: RouteTag = hex_vec(&f["dstTagHex"]).try_into().unwrap();
        let claimed: RouteTag = hex_vec(&f["claimedSrcTagHex"]).try_into().unwrap();
        let payload = hex_vec(&f["payloadHex"]);
        let sent = encode_frame(&dst, &claimed, &payload);
        assert_eq!(sent, hex_vec(&f["sentFrameHex"]));
        let delivered = hex_vec(&f["deliveredFrameHex"]);
        let (d, s, p) = decode_frame(&delivered).unwrap();
        assert_eq!(d, dst);
        assert_eq!(s.to_vec(), hex_vec(&v["topics"][0]["routeTagAHex"]));
        assert_eq!(p, payload.as_slice());
        // Header only (empty payload) and short frames are not frames.
        assert!(decode_frame(&delivered[..16]).is_none());
        assert!(decode_frame(&[1, 2, 3]).is_none());
    }

    // ---- state machine --------------------------------------------------------------------------------------

    const T: i64 = 1_000_000;

    struct Rig {
        client: RelayClient,
        env: TestEnv,
        sk: SigningKey,
        keys: TopicKeys,
        origin: String,
    }

    fn rig() -> Rig {
        let v = vectors();
        let (sk, _) = device(&v, "A");
        let keys = TopicKeys::derive(&secret(&v), 1);
        let mut client = RelayClient::new(sk.clone());
        let origin = v["relayOrigin"].as_str().unwrap().to_owned();
        client.configure(true, &origin, T);
        client.set_topic(Some(keys.clone()), T);
        Rig {
            client,
            env: TestEnv::new(7, T),
            sk,
            keys,
            origin,
        }
    }

    fn challenge(nonce: [u8; 32], pow_bits: u32) -> String {
        json!({"type": "relay.challenge", "nonce": B64.encode(nonce), "powBits": pow_bits})
            .to_string()
    }

    fn connect(r: &mut Rig) {
        assert!(matches!(
            r.client.begin_connect(T),
            Some(RelayOut::Connect { url }) if url == format!("{}/connect", r.origin)
        ));
        assert_eq!(r.client.state(), RelayState::Connecting);
        r.client.socket_opened(T);
        assert_eq!(r.client.state(), RelayState::AwaitingChallenge);
    }

    fn only_text(outs: Vec<RelayOut>) -> Value {
        match outs.as_slice() {
            [RelayOut::SendText(t)] => serde_json::from_str(t).unwrap(),
            other => panic!("expected one SendText, got {other:?}"),
        }
    }

    #[test]
    fn the_join_message_matches_the_vector() {
        let v = vectors();
        let mut r = rig();
        connect(&mut r);
        let nonce = hex32(&v["join"]["nonceHex"]);
        let outs = r.client.text_received(T, &mut r.env, &challenge(nonce, 0));
        let join = only_text(outs);
        let mut expected = v["join"]["joinMessage"].clone();
        expected.as_object_mut().unwrap().remove("pow");
        assert_eq!(join, expected);
        assert_eq!(r.client.state(), RelayState::Joining);
    }

    fn joined_text(own: &RouteTag, members: &[RouteTag]) -> String {
        json!({
            "type": "relay.joined",
            "routeTag": B64.encode(own),
            "members": members.iter().map(|m| B64.encode(m)).collect::<Vec<_>>(),
            "limits": {"maxFrameBytes": 16777232u64},
        })
        .to_string()
    }

    #[test]
    fn happy_path_joins_tracks_presence_and_delivers() {
        let mut r = rig();
        connect(&mut r);
        let own = route_tag_for_key(&r.keys.topic_id, &r.sk.verifying_key().to_bytes());
        r.client
            .text_received(T, &mut r.env, &challenge([9; 32], 0));
        let peer: RouteTag = [5; 8];
        let outs = r
            .client
            .text_received(T, &mut r.env, &joined_text(&own, &[peer]));
        assert_eq!(
            outs,
            vec![
                RelayOut::Joined {
                    route_tag: own,
                    members: vec![peer]
                },
                RelayOut::PeerSeen(peer)
            ]
        );
        assert!(r.client.is_joined());
        let later: RouteTag = [6; 8];
        let msg =
            |t: &str, tag: &RouteTag| json!({"type": t, "routeTag": B64.encode(tag)}).to_string();
        assert_eq!(
            r.client
                .text_received(T, &mut r.env, &msg("relay.peer_joined", &later)),
            vec![RelayOut::PeerSeen(later)]
        );
        assert_eq!(
            r.client
                .text_received(T, &mut r.env, &msg("relay.peer_left", &later)),
            vec![RelayOut::PeerGone(later)]
        );
        // A second peer_left for an unknown tag says nothing.
        assert!(r
            .client
            .text_received(T, &mut r.env, &msg("relay.peer_left", &later))
            .is_empty());

        let frame = encode_frame(&own, &peer, b"hello");
        assert_eq!(
            r.client.binary_received(&frame),
            vec![RelayOut::Deliver {
                src: peer,
                payload: b"hello".to_vec()
            }]
        );
        assert!(r.client.binary_received(&frame[..16]).is_empty());
        let out = r.client.frames_for(&peer, b"abc");
        assert_eq!(out, vec![encode_frame(&peer, &own, b"abc")]);
        assert!(r.client.frames_for(&peer, b"").is_empty());
    }

    #[test]
    fn pow_required_solves_and_retries_on_the_same_connection() {
        let v = vectors();
        let mut r = rig();
        connect(&mut r);
        let nonce = hex32(&v["join"]["nonceHex"]);
        r.client.text_received(T, &mut r.env, &challenge(nonce, 12));
        let outs = r.client.text_received(
            T,
            &mut r.env,
            &json!({"type": "relay.error", "code": "pow_required"}).to_string(),
        );
        let join = only_text(outs);
        let pow: [u8; 8] = B64
            .decode(join["pow"].as_str().unwrap())
            .unwrap()
            .try_into()
            .unwrap();
        let key_hash = public_key_hash(&r.sk.verifying_key().to_bytes());
        assert!(check_pow(&key_hash, &nonce, &pow, 12));
        assert_eq!(r.client.state(), RelayState::Joining);
    }

    #[test]
    fn too_hard_pow_and_repeated_pow_errors_give_up_with_backoff() {
        let mut r = rig();
        connect(&mut r);
        r.client
            .text_received(T, &mut r.env, &challenge([1; 32], 30));
        let outs = r.client.text_received(
            T,
            &mut r.env,
            &json!({"type": "relay.error", "code": "pow_required"}).to_string(),
        );
        assert!(outs.contains(&RelayOut::Error("pow_too_hard".into())));
        assert!(outs.contains(&RelayOut::Close));
        assert_eq!(r.client.state(), RelayState::Disconnected);
        assert!(r.client.reconnect_at() >= T + 3_600_000);

        let mut r = rig();
        connect(&mut r);
        r.client
            .text_received(T, &mut r.env, &challenge([1; 32], 4));
        let err = json!({"type": "relay.error", "code": "pow_invalid"}).to_string();
        // Attempt 1 (no pow) -> 2 -> 3 are retried; the third failure closes.
        assert!(!r.client.text_received(T, &mut r.env, &err).is_empty());
        assert!(!r.client.text_received(T, &mut r.env, &err).is_empty());
        let outs = r.client.text_received(T, &mut r.env, &err);
        assert!(outs.contains(&RelayOut::Close));
        assert_eq!(r.client.state(), RelayState::Disconnected);
    }

    #[test]
    fn fatal_errors_use_long_backoff_and_throttling_does_not_disconnect() {
        for (code, floor) in [
            ("upgrade_required", 3_600_000),
            ("denied", 3_600_000),
            ("disabled", 600_000),
            ("join_failed", 30_000),
        ] {
            let mut r = rig();
            connect(&mut r);
            r.client
                .text_received(T, &mut r.env, &challenge([1; 32], 0));
            let outs = r.client.text_received(
                T,
                &mut r.env,
                &json!({"type": "relay.error", "code": code}).to_string(),
            );
            assert_eq!(outs, vec![RelayOut::Error(code.into()), RelayOut::Close]);
            assert!(!r.client.should_connect(T + floor - 1), "{code}");
            assert!(r.client.should_connect(T + floor.max(BACKOFF_MAX_MS) + 1));
        }
        let mut r = rig();
        connect(&mut r);
        let own = route_tag_for_key(&r.keys.topic_id, &r.sk.verifying_key().to_bytes());
        r.client
            .text_received(T, &mut r.env, &challenge([1; 32], 0));
        r.client
            .text_received(T, &mut r.env, &joined_text(&own, &[]));
        let outs = r.client.text_received(
            T,
            &mut r.env,
            &json!({"type": "relay.error", "code": "rate_limited"}).to_string(),
        );
        assert_eq!(outs, vec![RelayOut::Error("rate_limited".into())]);
        assert!(r.client.is_joined());
    }

    #[test]
    fn backoff_grows_stays_within_jittered_bounds_and_resets_on_join() {
        let mut r = rig();
        let mut now = T;
        let mut last_full = 0;
        for n in 1..=12u32 {
            assert!(r.client.begin_connect(now).is_some());
            let outs = r.client.socket_closed(now, &mut r.env);
            assert!(outs.is_empty());
            let full = (BACKOFF_BASE_MS << (n - 1).min(16)).min(BACKOFF_MAX_MS);
            let wait = r.client.reconnect_at() - now;
            assert!(
                wait >= full / 2 && wait <= full,
                "attempt {n}: {wait} not in [{}, {full}]",
                full / 2
            );
            assert!(full >= last_full);
            last_full = full;
            assert!(!r.client.should_connect(now + full / 2 - 1));
            now = r.client.reconnect_at();
        }
        assert_eq!(last_full, BACKOFF_MAX_MS);
        // Joining resets the exponent.
        connect_at(&mut r, now);
        let own = route_tag_for_key(&r.keys.topic_id, &r.sk.verifying_key().to_bytes());
        r.client
            .text_received(now, &mut r.env, &challenge([1; 32], 0));
        r.client
            .text_received(now, &mut r.env, &joined_text(&own, &[]));
        let outs = r.client.socket_closed(now, &mut r.env);
        assert_eq!(outs, vec![RelayOut::Down]);
        assert!(r.client.reconnect_at() - now <= BACKOFF_BASE_MS);
    }

    fn connect_at(r: &mut Rig, now: i64) {
        assert!(r.client.begin_connect(now).is_some());
        r.client.socket_opened(now);
    }

    #[test]
    fn stuck_connections_time_out_and_disable_or_new_topic_tears_down() {
        let mut r = rig();
        r.client.begin_connect(T).unwrap();
        assert!(r.client.tick(T + 1000, &mut r.env).is_empty());
        let outs = r.client.tick(T + CONNECT_TIMEOUT_MS + 1, &mut r.env);
        assert!(outs.contains(&RelayOut::Close));
        assert_eq!(r.client.state(), RelayState::Disconnected);

        let mut r = rig();
        connect(&mut r);
        let own = route_tag_for_key(&r.keys.topic_id, &r.sk.verifying_key().to_bytes());
        r.client
            .text_received(T, &mut r.env, &challenge([1; 32], 0));
        r.client
            .text_received(T, &mut r.env, &joined_text(&own, &[]));
        let outs = r
            .client
            .set_topic(Some(TopicKeys::derive(&[9; 32], 2)), T + 5);
        assert_eq!(outs, vec![RelayOut::Close, RelayOut::Down]);
        assert!(r.client.should_connect(T + 5));
        // Same topic again changes nothing.
        assert!(r
            .client
            .set_topic(Some(TopicKeys::derive(&[9; 32], 2)), T + 6)
            .is_empty());
        connect_at(&mut r, T + 6);
        let outs = r.client.configure(false, "", T + 7);
        assert_eq!(outs, vec![RelayOut::Close]);
        assert!(!r.client.should_connect(T + 1_000_000_000));
    }

    #[test]
    fn origins_are_normalised_and_validated() {
        assert_eq!(
            normalize_origin("wss://relay.example.test/"),
            Some((
                "wss://relay.example.test".into(),
                "wss://relay.example.test/connect".into()
            ))
        );
        assert_eq!(
            normalize_origin("ws://localhost:8080/connect").unwrap().0,
            "ws://localhost:8080"
        );
        assert_eq!(normalize_origin("https://x"), None);
        assert_eq!(normalize_origin("wss://"), None);
        assert_eq!(normalize_origin("wss://a b"), None);
        let mut c = RelayClient::new(SigningKey::from_bytes(&[1; 32]));
        assert_eq!(
            c.configure(true, "http://nope", 0),
            vec![RelayOut::Error("bad_origin".into())]
        );
        assert!(!c.is_enabled());
    }

    #[test]
    fn garbage_is_ignored() {
        let mut r = rig();
        connect(&mut r);
        for t in [
            "",
            "not json",
            "[]",
            "{}",
            "{\"type\":5}",
            "{\"type\":\"relay.joined\"}",
        ] {
            let _ = r.client.text_received(T, &mut r.env, t);
        }
        // A challenge with a short nonce fails the attempt.
        let mut r = rig();
        connect(&mut r);
        let outs = r.client.text_received(
            T,
            &mut r.env,
            &json!({"type":"relay.challenge","nonce":"AAAA","powBits":0}).to_string(),
        );
        assert!(outs.contains(&RelayOut::Close));
    }
}
