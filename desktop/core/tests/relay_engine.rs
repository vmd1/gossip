//! The relay client inside the engine, over an in-test relay hub that implements the server's join and routing
//! rules (relay/src/hub.ts) closely enough to exercise the real client end to end.

use std::collections::{HashMap, HashSet, VecDeque};

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use ed25519_dalek::{Signature, SigningKey, Verifier, VerifyingKey};
use gossip_core::crypto::noise::StaticKeypair;
use gossip_core::engine::*;
use gossip_core::env::TestEnv;
use gossip_core::features::FeatureSettings;
use gossip_core::relay::{self, RouteTag};
use gossip_core::trust::TrustSnapshot;
use gossip_core::wire::envelope::Envelope;
use gossip_core::wire::handshake::DeviceType;
use gossip_core::wire::uuid;
use serde_json::{json, Value};

const T0: i64 = 1_760_000_000_000;
const ORIGIN: &str = "wss://relay.example.test";

fn id_of(n: u8) -> String {
    uuid::format(&[n; 16])
}

fn identity(n: u8) -> Identity {
    Identity {
        device_id: id_of(n),
        device_name: format!("Device {n}"),
        device_type: DeviceType::Mac,
        noise: StaticKeypair::from_secret_bytes([n; 32]),
        signing: SigningKey::from_bytes(&[n.wrapping_add(100); 32]),
    }
}

struct Sock {
    nonce: [u8; 32],
    tag: Option<RouteTag>,
    topic: Option<[u8; 32]>,
    attempts: u8,
}

struct Node {
    core: Core<TestEnv>,
    events: Vec<Event>,
    sock: Option<Sock>,
    seed: u8,
}

type HubTopic = (Vec<u8>, HashMap<RouteTag, usize>);

#[derive(Default)]
struct Hub {
    pow_bits: u32,
    known: HashSet<[u8; 32]>,
    topics: HashMap<[u8; 32], HubTopic>,
    /// Re-slice every relayed payload into messages of this size.
    chunk: Option<usize>,
    /// Silently swallow all data frames.
    blackhole: bool,
    sockets: u32,
    forwarded: usize,
}

enum Item {
    Act(usize, Action),
    Text(usize, String),
    Bin(usize, Vec<u8>),
}

struct World {
    nodes: Vec<Node>,
    lan: HashMap<(usize, ConnId), (usize, ConnId)>,
    next_conn: ConnId,
    hub: Hub,
    now: i64,
}

impl World {
    fn new() -> Self {
        Self {
            nodes: Vec::new(),
            lan: HashMap::new(),
            next_conn: 1,
            hub: Hub::default(),
            now: T0,
        }
    }

    fn add(&mut self, n: u8) -> usize {
        self.nodes.push(Node {
            core: Core::new(
                TestEnv::new(n, T0),
                identity(n),
                TrustSnapshot::default(),
                FeatureSettings::all_enabled(),
            ),
            events: Vec::new(),
            sock: None,
            seed: n,
        });
        self.nodes.len() - 1
    }

    fn id(&self, n: usize) -> String {
        id_of(self.nodes[n].seed)
    }

    fn set_time(&mut self, ms: i64) {
        self.now = ms;
        for n in &mut self.nodes {
            n.core.env_mut().now = ms;
        }
    }

    fn pump(&mut self, node: usize, actions: Vec<Action>) {
        let mut q: VecDeque<Item> = actions.into_iter().map(|a| Item::Act(node, a)).collect();
        while let Some(item) = q.pop_front() {
            match item {
                Item::Text(n, t) => {
                    let acts = self.nodes[n].core.relay_text_received(&t);
                    q.extend(acts.into_iter().map(|a| Item::Act(n, a)));
                }
                Item::Bin(n, b) => {
                    let acts = self.nodes[n].core.relay_binary_received(&b);
                    q.extend(acts.into_iter().map(|a| Item::Act(n, a)));
                }
                Item::Act(n, action) => self.act(n, action, &mut q),
            }
        }
    }

    fn act(&mut self, n: usize, action: Action, q: &mut VecDeque<Item>) {
        match action {
            Action::Send { conn, bytes } => {
                if let Some(&(peer, pc)) = self.lan.get(&(n, conn)) {
                    let more = self.nodes[peer].core.bytes_received(pc, &bytes);
                    q.extend(more.into_iter().map(|a| Item::Act(peer, a)));
                }
            }
            Action::Close { conn } => {
                if let Some((peer, pc)) = self.lan.remove(&(n, conn)) {
                    self.lan.remove(&(peer, pc));
                    let more = self.nodes[peer].core.connection_closed(pc);
                    q.extend(more.into_iter().map(|a| Item::Act(peer, a)));
                }
            }
            Action::Event(e) => self.nodes[n].events.push(e),
            Action::RelayConnect { url } => {
                assert_eq!(url, format!("{ORIGIN}/connect"));
                self.hub.sockets += 1;
                let mut nonce = [0u8; 32];
                nonce[..4].copy_from_slice(&self.hub.sockets.to_be_bytes());
                self.nodes[n].sock = Some(Sock {
                    nonce,
                    tag: None,
                    topic: None,
                    attempts: 0,
                });
                let more = self.nodes[n].core.relay_socket_opened();
                q.extend(more.into_iter().map(|a| Item::Act(n, a)));
                q.push_back(Item::Text(
                    n,
                    json!({"type": "relay.challenge", "nonce": B64.encode(nonce), "powBits": self.hub.pow_bits})
                        .to_string(),
                ));
            }
            Action::RelayClose => self.hub_remove(n, q),
            Action::RelaySendText { text } => self.hub_join(n, &text, q),
            Action::RelaySendBinary { bytes } => self.hub_route(n, bytes, q),
        }
    }

    fn err(code: &str) -> String {
        json!({"type": "relay.error", "code": code}).to_string()
    }

    fn hub_join(&mut self, n: usize, text: &str, q: &mut VecDeque<Item>) {
        let m: Value = serde_json::from_str(text).unwrap();
        assert_eq!(m["type"], "relay.join");
        let dec = |f: &str| B64.decode(m[f].as_str().unwrap()).unwrap();
        let pk: [u8; 32] = dec("publicKey").try_into().unwrap();
        let topic_id: [u8; 32] = dec("topicId").try_into().unwrap();
        let sig: [u8; 64] = dec("sig").try_into().unwrap();
        let verifier: [u8; 32] = dec("verifier").try_into().unwrap();
        let proof: [u8; 32] = dec("proof").try_into().unwrap();
        let sock = self.nodes[n]
            .sock
            .as_mut()
            .expect("joined without a socket");
        sock.attempts += 1;
        let nonce = sock.nonce;
        let signed = relay::join_signing_input(ORIGIN, &nonce, &topic_id);
        let vk = VerifyingKey::from_bytes(&pk).unwrap();
        assert!(
            vk.verify(&signed, &Signature::from_bytes(&sig)).is_ok(),
            "bad join signature"
        );
        assert_eq!(proof, relay::join_proof(&verifier, &nonce));
        let key_hash = relay::public_key_hash(&pk);
        if self.hub.pow_bits > 0 && !self.hub.known.contains(&key_hash) {
            let pow = m.get("pow").and_then(Value::as_str);
            match pow.map(|p| B64.decode(p).unwrap()) {
                None => return q.push_back(Item::Text(n, Self::err("pow_required"))),
                Some(p) => {
                    let p: [u8; 8] = p.try_into().unwrap();
                    if !relay::check_pow(&key_hash, &nonce, &p, self.hub.pow_bits) {
                        return q.push_back(Item::Text(n, Self::err("pow_invalid")));
                    }
                }
            }
        }
        self.hub.known.insert(key_hash);
        let tag = relay::route_tag(&topic_id, &key_hash);
        let (v, members) = self
            .hub
            .topics
            .entry(topic_id)
            .or_insert_with(|| (verifier.to_vec(), HashMap::new()));
        if *v != verifier.to_vec() {
            self.nodes[n].sock = None;
            return q.push_back(Item::Text(n, Self::err("join_failed")));
        }
        let others: Vec<(RouteTag, usize)> = members.iter().map(|(t, i)| (*t, *i)).collect();
        members.insert(tag, n);
        let sock = self.nodes[n].sock.as_mut().unwrap();
        sock.tag = Some(tag);
        sock.topic = Some(topic_id);
        q.push_back(Item::Text(
            n,
            json!({
                "type": "relay.joined",
                "routeTag": B64.encode(tag),
                "members": others.iter().map(|(t, _)| B64.encode(t)).collect::<Vec<_>>(),
                "limits": {"maxFrameBytes": 16777232u64},
            })
            .to_string(),
        ));
        for (_, i) in others {
            q.push_back(Item::Text(
                i,
                json!({"type": "relay.peer_joined", "routeTag": B64.encode(tag)}).to_string(),
            ));
        }
    }

    fn hub_remove(&mut self, n: usize, q: &mut VecDeque<Item>) {
        let Some(sock) = self.nodes[n].sock.take() else {
            return;
        };
        let (Some(tag), Some(topic)) = (sock.tag, sock.topic) else {
            return;
        };
        if let Some((_, members)) = self.hub.topics.get_mut(&topic) {
            members.remove(&tag);
            for i in members.values() {
                q.push_back(Item::Text(
                    *i,
                    json!({"type": "relay.peer_left", "routeTag": B64.encode(tag)}).to_string(),
                ));
            }
        }
    }

    fn hub_route(&mut self, n: usize, mut frame: Vec<u8>, q: &mut VecDeque<Item>) {
        let sock = self.nodes[n].sock.as_ref().expect("frame without a socket");
        let (Some(tag), Some(topic)) = (sock.tag, sock.topic) else {
            panic!("data frame before join");
        };
        if self.hub.blackhole || frame.len() <= relay::HEADER_LEN {
            return;
        }
        let dst: RouteTag = frame[..8].try_into().unwrap();
        frame[8..16].copy_from_slice(&tag);
        let Some(&target) = self.hub.topics[&topic].1.get(&dst) else {
            return;
        };
        self.hub.forwarded += 1;
        match self.hub.chunk {
            None => q.push_back(Item::Bin(target, frame)),
            Some(size) => {
                for piece in frame[16..].chunks(size) {
                    q.push_back(Item::Bin(target, relay::encode_frame(&dst, &tag, piece)));
                }
            }
        }
    }

    /// The relay connection of `n` dies without the core asking.
    fn kill_socket(&mut self, n: usize) {
        let mut q = VecDeque::new();
        self.hub_remove(n, &mut q);
        let acts = self.nodes[n].core.relay_socket_closed();
        let mut items: VecDeque<Item> = acts.into_iter().map(|a| Item::Act(n, a)).collect();
        items.extend(q);
        self.drain(items);
    }

    fn drain(&mut self, items: VecDeque<Item>) {
        // Re-enter the normal pump one item at a time.
        let mut q = items;
        while let Some(item) = q.pop_front() {
            match item {
                Item::Text(n, t) => {
                    let acts = self.nodes[n].core.relay_text_received(&t);
                    q.extend(acts.into_iter().map(|a| Item::Act(n, a)));
                }
                Item::Bin(n, b) => {
                    let acts = self.nodes[n].core.relay_binary_received(&b);
                    q.extend(acts.into_iter().map(|a| Item::Act(n, a)));
                }
                Item::Act(n, a) => self.act(n, a, &mut q),
            }
        }
    }

    fn relay_on(&mut self, n: usize) {
        let acts = self.nodes[n].core.relay_configure(true, ORIGIN);
        self.pump(n, acts);
    }

    fn tick_all(&mut self) {
        for n in 0..self.nodes.len() {
            let acts = self.nodes[n].core.tick();
            self.pump(n, acts);
        }
    }

    /// Advances time in one-second steps, ticking every node.
    fn advance(&mut self, secs: i64) {
        for _ in 0..secs {
            self.set_time(self.now + 1000);
            self.tick_all();
        }
    }

    // ---- LAN ----------------------------------------------------------------------------------------------

    fn open_lan(&mut self, dialer: usize, listener: usize, pairing: Option<&str>) {
        let (a, b) = (self.next_conn, self.next_conn + 1);
        self.next_conn += 2;
        self.lan.insert((dialer, a), (listener, b));
        self.lan.insert((listener, b), (dialer, a));
        let accept = self.nodes[listener].core.connection_accepted(b).unwrap();
        self.pump(listener, accept);
        let target = self.id(listener);
        let key = StaticKeypair::from_secret_bytes([self.nodes[listener].seed; 32]).public_bytes();
        let dial = self.nodes[dialer]
            .core
            .dial(
                a,
                &target,
                key,
                pairing.map(|t| PairingIntent { token: t.into() }),
            )
            .unwrap();
        self.pump(dialer, dial);
    }

    fn prompt(&self, node: usize) -> Option<ConnId> {
        self.nodes[node].events.iter().rev().find_map(|e| match e {
            Event::PairingPrompt { conn, .. } => Some(*conn),
            _ => None,
        })
    }

    fn pair(&mut self, dialer: usize, listener: usize) {
        self.nodes[listener].core.arm_pairing("t");
        self.open_lan(dialer, listener, Some("t"));
        let lc = self.prompt(listener).unwrap();
        let dc = self.prompt(dialer).unwrap();
        let acts = self.nodes[listener].core.confirm_pairing(lc, true);
        self.pump(listener, acts);
        let acts = self.nodes[dialer].core.confirm_pairing(dc, true);
        self.pump(dialer, acts);
        assert!(self.nodes[dialer].core.is_connected(&self.id(listener)));
    }

    fn cut_lan(&mut self, a: usize, b: usize) {
        let keys: Vec<(usize, ConnId)> = self
            .lan
            .iter()
            .filter(|((x, _), (y, _))| *x == a && *y == b)
            .map(|(k, _)| *k)
            .collect();
        for (x, c) in keys {
            let (y, yc) = self.lan.remove(&(x, c)).unwrap();
            self.lan.remove(&(y, yc));
            let acts = self.nodes[x].core.connection_closed(c);
            self.pump(x, acts);
            let acts = self.nodes[y].core.connection_closed(yc);
            self.pump(y, acts);
        }
    }

    fn send(&mut self, n: usize, e: Envelope) -> Result<(), SendError> {
        let acts = self.nodes[n].core.send(e)?;
        self.pump(n, acts);
        Ok(())
    }

    fn delivered(&mut self, n: usize) -> Vec<Envelope> {
        let mut out = Vec::new();
        self.nodes[n].events.retain(|e| match e {
            Event::Deliver { envelope, .. } if envelope.kind.starts_with("presence.") => false,
            Event::Deliver { envelope, .. } => {
                out.push(envelope.clone());
                false
            }
            _ => true,
        });
        out
    }

    fn count(&self, n: usize, f: impl Fn(&Event) -> bool) -> usize {
        self.nodes[n].events.iter().filter(|e| f(e)).count()
    }

    fn clear_events(&mut self) {
        for n in &mut self.nodes {
            n.events.clear();
        }
    }

    fn msg(&mut self, from: usize, kind: &str, to: usize) -> Envelope {
        let target = self.id(to);
        self.nodes[from].core.new_envelope(kind).to(&target)
    }
}

/// a (id 1) and b (id 2) paired over LAN, relay enabled on both, LAN then cut: the relay is the only path.
fn relay_pair(w: &mut World) -> (usize, usize) {
    let a = w.add(1);
    let b = w.add(2);
    w.pair(b, a);
    w.relay_on(a);
    w.relay_on(b);
    assert_eq!(w.nodes[a].core.topic_id(), w.nodes[b].core.topic_id());
    assert!(w.nodes[a].core.topic_id().is_some());
    w.cut_lan(a, b);
    (a, b)
}

#[test]
fn two_cores_handshake_and_exchange_messages_across_the_relay() {
    let mut w = World::new();
    w.hub.pow_bits = 10;
    let (a, b) = relay_pair(&mut w);
    assert_eq!(w.nodes[a].core.relay_status(), RelayStatus::Joined);
    assert!(!w.nodes[a].core.is_connected(&w.id(b)));

    // Inside the LAN grace nobody dials.
    w.advance(7);
    assert!(!w.nodes[a].core.is_connected(&w.id(b)));
    w.advance(3);
    assert!(w.nodes[a].core.is_connected(&w.id(b)));
    assert!(w.nodes[b].core.is_connected(&w.id(a)));
    assert!(w.nodes[a].core.is_relayed(&w.id(b)));
    assert!(w.nodes[b].core.is_relayed(&w.id(a)));

    let m = w.msg(a, "clipboard.update", b);
    w.send(a, m).unwrap();
    let got = w.delivered(b);
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].kind, "clipboard.update");
    let m = w.msg(b, "clipboard.update", a);
    w.send(b, m).unwrap();
    assert_eq!(w.delivered(a).len(), 1);
}

#[test]
fn relayed_streams_may_be_fragmented_and_a_raw_followup_travels_in_one_write() {
    let mut w = World::new();
    w.hub.chunk = Some(7);
    let (a, b) = relay_pair(&mut w);
    w.advance(10);
    assert!(w.nodes[a].core.is_relayed(&w.id(b)));
    let e = w.msg(a, "clipboard.update", b);
    let raw = vec![0xabu8; 5000];
    let acts = w.nodes[a].core.send_with_raw(e, &raw).unwrap();
    w.pump(a, acts);
    let delivered: Vec<(Envelope, Option<Vec<u8>>)> = w.nodes[b]
        .events
        .iter()
        .filter_map(|e| match e {
            Event::Deliver { envelope, raw } if envelope.kind == "clipboard.update" => {
                Some((envelope.clone(), raw.clone()))
            }
            _ => None,
        })
        .collect();
    assert_eq!(delivered.len(), 1);
    assert_eq!(delivered[0].1.as_deref(), Some(raw.as_slice()));
}

#[test]
fn relay_link_drops_and_returns_with_the_socket() {
    let mut w = World::new();
    let (a, b) = relay_pair(&mut w);
    w.advance(10);
    assert!(w.nodes[a].core.is_relayed(&w.id(b)));
    w.clear_events();

    w.kill_socket(b);
    assert!(!w.nodes[b].core.is_connected(&w.id(a)));
    assert_eq!(w.nodes[b].core.relay_status(), RelayStatus::Disconnected);
    assert_eq!(
        w.count(b, |e| matches!(e, Event::PeerDisconnected { .. })),
        1
    );
    assert_eq!(w.count(b, |e| matches!(e, Event::RelayDown)), 1);
    // The relay told a the peer left.
    assert!(!w.nodes[a].core.is_connected(&w.id(b)));

    // Backoff (2s base, jittered), then reconnect, rejoin and redial after the grace.
    w.advance(30);
    assert_eq!(w.nodes[b].core.relay_status(), RelayStatus::Joined);
    assert!(w.nodes[a].core.is_relayed(&w.id(b)), "link restored");
}

#[test]
fn lan_is_preferred_and_replaces_a_relayed_link_without_a_flap() {
    let mut w = World::new();
    let (a, b) = relay_pair(&mut w);
    w.advance(10);
    assert!(w.nodes[a].core.is_relayed(&w.id(b)));
    // The shell keeps trying LAN: a relayed link does not stop it.
    assert!(w.nodes[a].core.should_dial(&w.id(b)));
    w.clear_events();

    w.open_lan(b, a, None);
    assert!(w.nodes[a].core.is_connected(&w.id(b)));
    assert!(!w.nodes[a].core.is_relayed(&w.id(b)));
    assert!(!w.nodes[b].core.is_relayed(&w.id(a)));
    for n in [a, b] {
        assert_eq!(
            w.count(n, |e| matches!(e, Event::PeerDisconnected { .. })),
            0,
            "no disconnect event when LAN replaces the relay link"
        );
    }
    // A direct link now exists, so no further LAN dial is wanted.
    assert!(!w.nodes[a].core.should_dial(&w.id(b)));

    // And it keeps working, and the relay never dials again while LAN is live.
    w.advance(40);
    let m = w.msg(a, "clipboard.update", b);
    w.send(a, m).unwrap();
    assert_eq!(w.delivered(b).len(), 1);
    assert!(!w.nodes[a].core.is_relayed(&w.id(b)));
}

#[test]
fn a_live_lan_link_means_the_relay_is_never_dialed() {
    let mut w = World::new();
    let a = w.add(1);
    let b = w.add(2);
    w.pair(b, a);
    w.relay_on(a);
    w.relay_on(b);
    w.advance(60);
    assert!(!w.nodes[a].core.is_relayed(&w.id(b)));
    assert!(w.nodes[a].core.is_connected(&w.id(b)));
    assert_eq!(w.hub.forwarded, 0, "no relayed traffic while LAN is up");
}

#[test]
fn only_the_lower_device_id_initiates_over_the_relay() {
    let mut w = World::new();
    let (a, b) = relay_pair(&mut w);
    // b (higher id) never dials: watch the first handshake frame come from a.
    w.advance(8);
    let first = w.hub.forwarded;
    w.advance(2);
    assert!(w.hub.forwarded > first);
    assert!(w.nodes[b].core.is_connected(&w.id(a)));
}

#[test]
fn screen_and_control_are_refused_over_a_relayed_link() {
    let mut w = World::new();
    let (a, b) = relay_pair(&mut w);
    w.advance(10);
    assert!(w.nodes[a].core.is_relayed(&w.id(b)));

    // Locally: nothing is sent.
    for kind in ["screen.start", "control.event"] {
        let m = w.msg(a, kind, b);
        assert_eq!(w.send(a, m), Err(SendError::NotConnected), "{kind}");
    }
    // A peer that sends them anyway is ignored.
    for kind in ["screen.start", "control.event"] {
        let id = w.id(b);
        let e = w.nodes[a].core.new_envelope(kind).to(&id);
        let acts = w.nodes[a]
            .core
            .send_unchecked_for_tests(&id, e, None)
            .unwrap();
        w.pump(a, acts);
    }
    assert!(w.delivered(b).is_empty());
    // Ordinary traffic still flows.
    let m = w.msg(a, "clipboard.update", b);
    w.send(a, m).unwrap();
    assert_eq!(w.delivered(b).len(), 1);
}

#[test]
fn screen_and_control_are_not_forwarded_onto_relayed_links() {
    let mut w = World::new();
    let a = w.add(1);
    let b = w.add(2);
    let c = w.add(3);
    w.pair(b, a);
    w.pair(c, a);
    // a introduces b and c to each other so b can verify c's signatures.
    let roster = w.nodes[a].core.roster_update(None);
    w.send(a, roster).unwrap();
    w.relay_on(a);
    w.relay_on(b);
    w.cut_lan(a, b);
    w.advance(10);
    assert!(w.nodes[a].core.is_relayed(&w.id(b)));
    assert!(w.nodes[a].core.is_connected(&w.id(c)) && !w.nodes[a].core.is_relayed(&w.id(c)));

    let screen = w.nodes[c].core.new_envelope("screen.frame").broadcast();
    let clip = w.nodes[c].core.new_envelope("clipboard.update").broadcast();
    w.send(c, screen).unwrap();
    w.send(c, clip).unwrap();
    assert_eq!(w.delivered(a).len(), 2, "a is on a direct link to c");
    let at_b: Vec<_> = w.delivered(b).into_iter().map(|e| e.kind).collect();
    assert_eq!(
        at_b,
        vec!["clipboard.update"],
        "screen.* is not forwarded over the relay"
    );
}

#[test]
fn unknown_or_untrusted_relay_senders_get_no_link() {
    let mut w = World::new();
    let (a, _b) = relay_pair(&mut w);
    let acts = w.nodes[a].core.relay_binary_received(&relay::encode_frame(
        &[1; 8],
        &[9; 8],
        b"\0\0\0\x05junk!",
    ));
    assert!(acts.is_empty());
}

#[test]
fn a_silent_relayed_peer_goes_stale_like_any_other() {
    let mut w = World::new();
    let (a, b) = relay_pair(&mut w);
    w.advance(10);
    assert!(w.nodes[a].core.is_relayed(&w.id(b)));
    // Healthy: heartbeats keep it alive well past the stale threshold.
    w.advance(100);
    assert!(w.nodes[a].core.is_relayed(&w.id(b)));
    w.clear_events();
    w.hub.blackhole = true;
    w.advance(70);
    assert!(!w.nodes[a].core.is_connected(&w.id(b)));
    assert_eq!(
        w.count(a, |e| matches!(e, Event::PeerDisconnected { .. })),
        1
    );
}

// ---- mesh.topic -----------------------------------------------------------------------------------------------

fn last_topic(w: &World, n: usize) -> Option<(Vec<u8>, u64)> {
    w.nodes[n].events.iter().rev().find_map(|e| match e {
        Event::TopicChanged { secret, epoch } => Some((secret.expose().to_vec(), *epoch)),
        _ => None,
    })
}

#[test]
fn the_first_pairing_mints_the_topic_and_both_devices_agree() {
    let mut w = World::new();
    let a = w.add(1);
    let b = w.add(2);
    assert_eq!(w.nodes[a].core.topic_epoch(), None);
    w.pair(b, a);
    assert_eq!(w.nodes[a].core.topic_epoch(), Some(1));
    assert_eq!(w.nodes[b].core.topic_epoch(), Some(1));
    assert_eq!(w.nodes[a].core.topic_id(), w.nodes[b].core.topic_id());
    // Whoever minted it reported it for persistence; the loser (if any) reported the adopted one.
    let held: Vec<_> = [a, b].iter().filter_map(|n| last_topic(&w, *n)).collect();
    assert!(!held.is_empty());
    let first = &held[0];
    assert!(held.iter().all(|h| h == first));
}

#[test]
fn conflicting_secrets_in_a_three_device_mesh_converge_on_the_highest_epoch_then_hash() {
    let mut w = World::new();
    let a = w.add(1);
    let b = w.add(2);
    let c = w.add(3);
    // Three different secrets; c is ahead by epoch.
    let _ = w.nodes[a].core.set_topic([0xa1; 32], 1);
    let _ = w.nodes[b].core.set_topic([0xb2; 32], 1);
    let _ = w.nodes[c].core.set_topic([0xc3; 32], 2);
    w.pair(b, a);
    w.pair(c, b);
    // a and c are not directly linked; b relays knowledge between them through its own resend.
    w.advance(1);
    assert_eq!(w.nodes[c].core.topic_epoch(), Some(2));
    for n in [a, b, c] {
        assert_eq!(w.nodes[n].core.topic_epoch(), Some(2), "node {n}");
        assert_eq!(w.nodes[n].core.topic_id(), w.nodes[c].core.topic_id());
    }

    // Same epoch, different secrets: the larger hash wins everywhere.
    let mut w = World::new();
    let a = w.add(1);
    let b = w.add(2);
    let c = w.add(3);
    for (n, s) in [(a, 0x11u8), (b, 0x22), (c, 0x33)] {
        let _ = w.nodes[n].core.set_topic([s; 32], 4);
    }
    w.pair(b, a);
    w.pair(c, b);
    w.pair(c, a);
    let ids: Vec<_> = [a, b, c]
        .iter()
        .map(|n| w.nodes[*n].core.topic_id())
        .collect();
    assert!(ids.iter().all(|i| *i == ids[0]), "{ids:?}");
    let winner = [0x11u8, 0x22, 0x33]
        .iter()
        .max_by_key(|s| {
            use sha2::{Digest, Sha256};
            Sha256::digest([**s; 32]).to_vec()
        })
        .copied()
        .unwrap();
    assert_eq!(
        ids[0],
        Some(gossip_core::relay::TopicKeys::derive(&[winner; 32], 4).topic_id)
    );
}

fn topic_msg(
    w: &mut World,
    from: usize,
    to: usize,
    secret: [u8; 32],
    epoch: u64,
) -> Result<(), SendError> {
    let id = w.id(to);
    let payload = json!({"topicSecret": B64.encode(secret), "epoch": epoch});
    let Value::Object(payload) = payload else {
        unreachable!()
    };
    let e = w.nodes[from]
        .core
        .new_envelope("mesh.topic")
        .to(&id)
        .with_ttl(0)
        .with_payload(payload);
    let acts = w.nodes[from].core.send_unchecked_for_tests(&id, e, None)?;
    w.pump(from, acts);
    Ok(())
}

#[test]
fn applying_mesh_topic_twice_is_a_no_op_and_stale_ones_are_answered_not_adopted() {
    let mut w = World::new();
    let a = w.add(1);
    let b = w.add(2);
    w.pair(b, a);
    let before = w.nodes[a].core.topic_id();
    w.clear_events();

    // Higher epoch: adopted once; the identical message again changes nothing and reports nothing.
    topic_msg(&mut w, b, a, [0x77; 32], 9).unwrap();
    assert_eq!(w.nodes[a].core.topic_epoch(), Some(9));
    assert_ne!(w.nodes[a].core.topic_id(), before);
    assert_eq!(w.count(a, |e| matches!(e, Event::TopicChanged { .. })), 1);
    let wire_before = w.hub.forwarded;
    topic_msg(&mut w, b, a, [0x77; 32], 9).unwrap();
    assert_eq!(w.count(a, |e| matches!(e, Event::TopicChanged { .. })), 1);
    assert_eq!(w.nodes[a].core.topic_epoch(), Some(9));
    assert_eq!(w.hub.forwarded, wire_before);

    // A lower epoch is not adopted; the sender gets the real one back.
    let id_a = w.nodes[a].core.topic_id();
    topic_msg(&mut w, b, a, [0x01; 32], 3).unwrap();
    assert_eq!(w.nodes[a].core.topic_id(), id_a);
    assert_eq!(w.nodes[b].core.topic_epoch(), Some(9));
    assert_eq!(w.nodes[b].core.topic_id(), id_a);

    // Garbage and broadcasts are ignored.
    let payload = json!({"topicSecret": "short", "epoch": 99});
    let Value::Object(payload) = payload else {
        unreachable!()
    };
    let idb = w.id(a);
    let e = w.nodes[b]
        .core
        .new_envelope("mesh.topic")
        .to(&idb)
        .with_ttl(0)
        .with_payload(payload);
    let acts = w.nodes[b]
        .core
        .send_unchecked_for_tests(&idb, e, None)
        .unwrap();
    w.pump(b, acts);
    assert_eq!(w.nodes[a].core.topic_epoch(), Some(9));
    let payload = json!({"topicSecret": B64.encode([5u8; 32]), "epoch": 99});
    let Value::Object(payload) = payload else {
        unreachable!()
    };
    let e = w.nodes[b]
        .core
        .new_envelope("mesh.topic")
        .broadcast()
        .with_ttl(0)
        .with_payload(payload);
    let acts = w.nodes[b]
        .core
        .send_unchecked_for_tests(&idb, e, None)
        .unwrap();
    w.pump(b, acts);
    assert_eq!(w.nodes[a].core.topic_epoch(), Some(9));
}

#[test]
fn the_topic_is_resent_on_the_periodic_resync_without_noise() {
    let mut w = World::new();
    let a = w.add(1);
    let b = w.add(2);
    w.pair(b, a);
    w.clear_events();
    // Keep the link healthy for 12 minutes; several 300 s resyncs fire and none of them change anything.
    w.advance(720);
    assert_eq!(w.count(a, |e| matches!(e, Event::TopicChanged { .. })), 0);
    assert_eq!(w.count(b, |e| matches!(e, Event::TopicChanged { .. })), 0);
    assert_eq!(
        w.count(
            a,
            |e| matches!(e, Event::ReconcileDue(d) if d.task == "mesh.topic")
        ),
        0,
        "the core answers this task itself"
    );
    // A device that missed the topic gets it from the resync alone.
    let mut w = World::new();
    let a = w.add(1);
    let b = w.add(2);
    w.pair(b, a);
    let _ = w.nodes[b].core.set_topic([0x42; 32], 1);
    let _ = w.nodes[a].core.set_topic([0x43; 32], 3);
    w.advance(310);
    assert_eq!(w.nodes[b].core.topic_epoch(), Some(3));
    assert_eq!(w.nodes[a].core.topic_id(), w.nodes[b].core.topic_id());
}

#[test]
fn revoking_a_device_bumps_the_topic_and_withholds_it_from_the_revoked_device() {
    let mut w = World::new();
    let a = w.add(1);
    let b = w.add(2);
    let c = w.add(3);
    w.pair(b, a);
    w.pair(c, a);
    w.advance(1);
    let e0 = w.nodes[a].core.topic_epoch().unwrap();
    assert_eq!(w.nodes[b].core.topic_id(), w.nodes[a].core.topic_id());
    assert_eq!(w.nodes[c].core.topic_id(), w.nodes[a].core.topic_id());
    let old_id = w.nodes[a].core.topic_id();

    let cid = w.id(c);
    let acts = w.nodes[a].core.revoke_device(&cid);
    w.pump(a, acts);
    w.advance(1);
    // a and b both bumped (revoke applied on each); one secret wins; c still holds the old one.
    assert!(w.nodes[a].core.topic_epoch().unwrap() > e0);
    assert_eq!(w.nodes[a].core.topic_id(), w.nodes[b].core.topic_id());
    assert_ne!(w.nodes[a].core.topic_id(), old_id);
    assert_eq!(
        w.nodes[c].core.topic_id(),
        old_id,
        "the revoked device never sees the new topic"
    );
    assert_eq!(w.nodes[c].core.topic_epoch(), Some(e0));

    // The revoke arriving again (resend, duplicate) bumps nothing.
    let epoch = w.nodes[a].core.topic_epoch();
    let cid = w.id(c);
    let acts = w.nodes[a].core.revoke_device(&cid);
    w.pump(a, acts);
    w.advance(1);
    assert_eq!(w.nodes[a].core.topic_epoch(), epoch);
    assert_eq!(w.nodes[b].core.topic_epoch(), epoch);
}

#[test]
fn debug_output_never_contains_the_topic_secret() {
    let mut w = World::new();
    let a = w.add(1);
    let b = w.add(2);
    w.pair(b, a);
    let (secret, _) = [a, b].iter().find_map(|n| last_topic(&w, *n)).unwrap();
    let dump = format!("{:?}", w.nodes[a].events) + &format!("{:?}", w.nodes[b].events);
    assert!(dump.contains("redacted"));
    let b64 = B64.encode(&secret);
    assert!(!dump.contains(&b64));
    assert!(!dump.contains(&hex::encode(&secret)));
}
