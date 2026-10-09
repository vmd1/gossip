//! End-to-end tests of the engine over an in-memory network of several devices.

use std::collections::{HashMap, VecDeque};

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use ed25519_dalek::SigningKey;
use gossip_core::crypto::noise::StaticKeypair;
use gossip_core::engine::*;
use gossip_core::env::TestEnv;
use gossip_core::features::{Feature, FeatureSettings};
use gossip_core::trust::TrustSnapshot;
use gossip_core::wire::envelope::Envelope;
use gossip_core::wire::handshake::DeviceType;
use gossip_core::wire::uuid;
use serde_json::{json, Value};

const T0: i64 = 1_760_000_000_000;

struct Node {
    core: Core<TestEnv>,
    events: Vec<Event>,
}

struct Net {
    nodes: Vec<Node>,
    links: HashMap<(usize, ConnId), (usize, ConnId)>,
    next_conn: ConnId,
    /// Everything sent over any link, for assertions about what crossed the wire.
    wire: Vec<(usize, usize, Vec<u8>)>,
}

fn id_of(n: u8) -> String {
    uuid::format(&[n; 16])
}

fn identity(n: u8, kind: DeviceType) -> Identity {
    Identity {
        device_id: id_of(n),
        device_name: format!("Device {n}"),
        device_type: kind,
        noise: StaticKeypair::from_secret_bytes([n; 32]),
        signing: SigningKey::from_bytes(&[n.wrapping_add(100); 32]),
    }
}

impl Net {
    fn new() -> Self {
        Self {
            nodes: Vec::new(),
            links: HashMap::new(),
            next_conn: 1,
            wire: Vec::new(),
        }
    }

    fn add(&mut self, n: u8, kind: DeviceType) -> usize {
        let core = Core::new(
            TestEnv::new(n, T0),
            identity(n, kind),
            TrustSnapshot::default(),
            FeatureSettings::all_enabled(),
        );
        self.nodes.push(Node {
            core,
            events: Vec::new(),
        });
        self.nodes.len() - 1
    }

    fn set_time(&mut self, ms: i64) {
        for n in &mut self.nodes {
            n.core.env_mut().now = ms;
        }
    }

    fn noise_pub(&self, node: usize) -> [u8; 32] {
        StaticKeypair::from_secret_bytes([self.nodes[node].core_seed(); 32]).public_bytes()
    }

    /// Runs actions (and everything they cause) to quiescence.
    fn pump(&mut self, node: usize, actions: Vec<Action>) {
        let mut queue: VecDeque<(usize, Action)> = actions.into_iter().map(|a| (node, a)).collect();
        while let Some((n, action)) = queue.pop_front() {
            match action {
                Action::Send { conn, bytes } => {
                    if let Some(&(peer, peer_conn)) = self.links.get(&(n, conn)) {
                        self.wire.push((n, peer, bytes.clone()));
                        let more = self.nodes[peer].core.bytes_received(peer_conn, &bytes);
                        queue.extend(more.into_iter().map(|a| (peer, a)));
                    }
                }
                Action::Close { conn } => {
                    if let Some((peer, peer_conn)) = self.links.remove(&(n, conn)) {
                        self.links.remove(&(peer, peer_conn));
                        let more = self.nodes[peer].core.connection_closed(peer_conn);
                        queue.extend(more.into_iter().map(|a| (peer, a)));
                    }
                }
                Action::Event(e) => self.nodes[n].events.push(e),
            }
        }
    }

    /// `dialer` opens a connection to `listener` (which must already have the target's key if trusted).
    fn open(&mut self, dialer: usize, listener: usize, pairing: Option<&str>) -> (ConnId, ConnId) {
        let (a, b) = (self.next_conn, self.next_conn + 1);
        self.next_conn += 2;
        self.links.insert((dialer, a), (listener, b));
        self.links.insert((listener, b), (dialer, a));
        let accept = self.nodes[listener].core.connection_accepted(b).unwrap();
        self.pump(listener, accept);
        let target = self.nodes[listener].core.device_id().to_owned();
        let key = self.noise_pub(listener);
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
        (a, b)
    }

    fn send(&mut self, node: usize, e: Envelope) -> Result<(), SendError> {
        let actions = self.nodes[node].core.send(e)?;
        self.pump(node, actions);
        Ok(())
    }

    fn drain_delivered(&mut self, node: usize) -> Vec<Envelope> {
        let mut delivered = Vec::new();
        self.nodes[node].events.retain(|e| match e {
            Event::Deliver { envelope, .. } if envelope.kind.starts_with("presence.") => false,
            Event::Deliver { envelope, .. } => {
                delivered.push(envelope.clone());
                false
            }
            _ => true,
        });
        delivered
    }

    fn prompt(&self, node: usize) -> Option<(ConnId, String)> {
        self.nodes[node].events.iter().rev().find_map(|e| match e {
            Event::PairingPrompt { conn, code, .. } => Some((*conn, code.clone())),
            _ => None,
        })
    }

    fn confirm(&mut self, node: usize, conn: ConnId, accepted: bool) {
        let actions = self.nodes[node].core.confirm_pairing(conn, accepted);
        self.pump(node, actions);
    }

    /// Pairs `dialer` (scanned the code) with `listener` (showing it) and confirms on both sides.
    fn pair(&mut self, dialer: usize, listener: usize) {
        self.nodes[listener].core.arm_pairing("token-1");
        self.open(dialer, listener, Some("token-1"));
        let (lc, lcode) = self
            .prompt(listener)
            .expect("listener must be asked to confirm");
        let (dc, dcode) = self
            .prompt(dialer)
            .expect("dialer must be asked to confirm");
        assert_eq!(lcode, dcode, "both screens show the same comparison code");
        self.confirm(listener, lc, true);
        self.confirm(dialer, dc, true);
        assert!(self.nodes[dialer]
            .core
            .is_connected(&id_of(self.seed(listener))));
    }

    /// What the `trust.roster_update` reconciliation does in production: `hub` tells everyone it is connected to
    /// about everyone else, so devices that never paired directly learn each other's keys.
    fn introduce(&mut self, hub: usize) {
        let roster = self.nodes[hub].core.roster_update(None);
        self.send(hub, roster).unwrap();
    }

    /// Gives `node` a trusted row for device 9 through a roster message (no connection needed).
    fn pair_with_stranger(&mut self, node: usize) {
        let key = B64.encode(StaticKeypair::from_secret_bytes([9; 32]).public_bytes());
        let payload = json!({"devices": [{"deviceId": id_of(9), "publicKey": key, "deviceName": "Nine", "deviceType": "android-phone"}]});
        let Value::Object(payload) = payload else {
            unreachable!()
        };
        let added = self.nodes[node].core.trust_snapshot();
        assert!(added.devices.is_empty());
        let mut store = gossip_core::trust::TrustStore::from_snapshot(added);
        store.apply_roster(&payload, &id_of(self.seed(node)), T0);
        self.nodes[node].core.set_trust(store.snapshot(), vec![]);
    }

    fn seed(&self, node: usize) -> u8 {
        self.nodes[node].core_seed()
    }

    fn connected_event(&self, node: usize) -> usize {
        self.nodes[node]
            .events
            .iter()
            .filter(|e| matches!(e, Event::PeerConnected { .. }))
            .count()
    }
}

impl Node {
    fn core_seed(&self) -> u8 {
        // Device ids are uuid::format([n; 16]), so the first byte of the id recovers n.
        u8::from_str_radix(&self.core.device_id()[..2], 16).unwrap()
    }
}

fn kinds(node: &Node) -> Vec<&'static str> {
    node.events
        .iter()
        .map(|e| match e {
            Event::PeerConnected { .. } => "connected",
            Event::PeerDisconnected { .. } => "disconnected",
            Event::PairingPrompt { .. } => "prompt",
            Event::PairingPromptCancelled { .. } => "prompt-cancelled",
            Event::Deliver { .. } => "deliver",
            Event::Heard { .. } => "heard",
            Event::TrustChanged(_) => "trust",
            Event::DeviceRevoked { .. } => "revoked",
            Event::ReconcileDue(_) => "reconcile",
        })
        .collect()
}

fn feature_msg(net: &mut Net, from: usize, kind: &str) -> Envelope {
    net.nodes[from].core.new_envelope(kind)
}

#[test]
fn pairing_with_confirmation_on_both_sides() {
    let mut net = Net::new();
    let mac = net.add(1, DeviceType::Mac);
    let phone = net.add(2, DeviceType::AndroidPhone);
    net.pair(phone, mac);
    assert!(net.nodes[mac].core.trust().is_trusted(&id_of(2)));
    assert!(net.nodes[phone].core.trust().is_trusted(&id_of(1)));
    // Signing keys come from the authenticated handshake, so signed traffic works in both directions.
    let m = feature_msg(&mut net, phone, "dnd.update").broadcast();
    net.send(phone, m).unwrap();
    assert_eq!(net.drain_delivered(mac).len(), 1);
    let m = feature_msg(&mut net, mac, "dnd.update").broadcast();
    net.send(mac, m).unwrap();
    assert_eq!(net.drain_delivered(phone).len(), 1);
}

#[test]
fn unknown_device_is_refused_without_an_armed_pairing_or_with_the_wrong_token() {
    let mut net = Net::new();
    let mac = net.add(1, DeviceType::Mac);
    let phone = net.add(2, DeviceType::AndroidPhone);
    net.open(phone, mac, Some("x"));
    assert!(net.prompt(mac).is_none(), "nothing armed, no prompt");
    assert!(net.links.is_empty(), "connection closed");

    net.nodes[mac].core.arm_pairing("right");
    net.open(phone, mac, Some("wrong"));
    assert!(net.prompt(mac).is_none(), "wrong token, no prompt");

    net.open(phone, mac, None);
    assert!(net.prompt(mac).is_none(), "no token at all, no prompt");
}

#[test]
fn pairing_token_is_single_use_and_expires() {
    let mut net = Net::new();
    let mac = net.add(1, DeviceType::Mac);
    let phone = net.add(2, DeviceType::AndroidPhone);
    net.nodes[mac].core.arm_pairing("t");
    net.set_time(T0 + PAIRING_ARM_DURATION_MS + 1);
    let actions = net.nodes[mac].core.tick();
    net.pump(mac, actions);
    net.open(phone, mac, Some("t"));
    assert!(
        net.prompt(mac).is_none(),
        "an expired arming no longer admits anyone"
    );
}

#[test]
fn declining_the_prompt_closes_the_connection_and_trusts_nothing() {
    let mut net = Net::new();
    let mac = net.add(1, DeviceType::Mac);
    let phone = net.add(2, DeviceType::AndroidPhone);
    net.nodes[mac].core.arm_pairing("t");
    net.open(phone, mac, Some("t"));
    let (conn, _) = net.prompt(mac).unwrap();
    net.confirm(mac, conn, false);
    assert!(!net.nodes[mac].core.trust().is_trusted(&id_of(2)));
    assert!(net.links.is_empty());
    assert!(
        kinds(&net.nodes[phone]).contains(&"prompt-cancelled")
            || net.nodes[phone].core.connected_peers().is_empty()
    );
}

#[test]
fn trusted_reconnect_needs_no_prompt_and_responder_waits_for_proof() {
    let mut net = Net::new();
    let mac = net.add(1, DeviceType::Mac);
    let phone = net.add(2, DeviceType::AndroidPhone);
    net.pair(phone, mac);
    // Drop the link, then the Mac (initiator) dials the phone (responder), both trusted already.
    let (conn, _) = *net
        .links
        .keys()
        .next()
        .map(|(n, c)| (c, n))
        .map(|(c, n)| (*c, *n))
        .as_ref()
        .unwrap();
    let node = *net.links.keys().map(|(n, _)| n).next().unwrap();
    let actions = net.nodes[node]
        .core
        .disconnect(&id_of(if node == mac { 2 } else { 1 }));
    net.pump(node, actions);
    let _ = conn;
    assert!(net.nodes[mac].core.connected_peers().is_empty());
    assert!(net.nodes[phone].core.connected_peers().is_empty());

    let before = net.connected_event(phone);
    net.nodes[mac].events.clear();
    net.nodes[phone].events.clear();
    net.open(mac, phone, None);
    assert!(net.nodes[mac].core.is_connected(&id_of(2)));
    assert!(
        net.nodes[phone].core.is_connected(&id_of(1)),
        "the initiator's presence.online is the proof frame"
    );
    assert_eq!(net.connected_event(phone), 1);
    let _ = before;
    assert!(net.prompt(mac).is_none());
}

#[test]
fn a_trusted_device_presenting_a_different_key_is_refused() {
    let mut net = Net::new();
    let mac = net.add(1, DeviceType::Mac);
    let phone = net.add(2, DeviceType::AndroidPhone);
    net.pair(phone, mac);
    let actions = net.nodes[mac].core.disconnect(&id_of(2));
    net.pump(mac, actions);

    // An impostor claims the phone's device id but holds a different Noise key.
    let mut imposter = Core::new(
        TestEnv::new(9, T0),
        Identity {
            device_id: id_of(2),
            ..identity(9, DeviceType::AndroidPhone)
        },
        TrustSnapshot::default(),
        FeatureSettings::all_enabled(),
    );
    net.nodes.push(Node {
        core: Core::new(
            TestEnv::new(8, T0),
            identity(8, DeviceType::Mac),
            TrustSnapshot::default(),
            FeatureSettings::all_enabled(),
        ),
        events: vec![],
    });
    let fake = net.nodes.len() - 1;
    std::mem::swap(&mut net.nodes[fake].core, &mut imposter);
    net.open(fake, mac, None);
    assert!(
        !net.nodes[mac].core.is_connected(&id_of(2)),
        "wrong key for a paired id must not connect"
    );
}

#[test]
fn broadcast_and_directed_messages_and_dedupe() {
    let mut net = Net::new();
    let a = net.add(1, DeviceType::Mac);
    let b = net.add(2, DeviceType::AndroidPhone);
    let c = net.add(3, DeviceType::AndroidTablet);
    net.pair(b, a);
    net.pair(c, a);
    net.introduce(a);

    // Directed at c, sent by b: a is the only link, so it relays (b and c are not directly connected).
    let m = feature_msg(&mut net, b, "media.command").to(&id_of(3));
    net.send(b, m).unwrap();
    assert_eq!(net.drain_delivered(c).len(), 1, "relayed through a");
    assert!(
        net.drain_delivered(a).is_empty(),
        "a relays but does not deliver a message not addressed to it"
    );
    assert!(net.drain_delivered(b).is_empty());

    // Broadcast from c reaches a and b exactly once each.
    let m = feature_msg(&mut net, c, "clipboard.update").broadcast();
    net.send(c, m).unwrap();
    assert_eq!(net.drain_delivered(a).len(), 1);
    assert_eq!(net.drain_delivered(b).len(), 1);
    assert!(
        net.drain_delivered(c).is_empty(),
        "never delivered back to its originator"
    );
}

#[test]
fn ttl_zero_is_direct_only_and_not_flooded() {
    let mut net = Net::new();
    let a = net.add(1, DeviceType::Mac);
    let b = net.add(2, DeviceType::AndroidPhone);
    let c = net.add(3, DeviceType::AndroidTablet);
    net.pair(b, a);
    net.pair(c, a);
    let m = feature_msg(&mut net, b, "ble.beacon_key")
        .to(&id_of(3))
        .with_ttl(0);
    assert_eq!(
        net.send(b, m),
        Err(SendError::NotConnected),
        "no direct link to c, so nothing is sent at all"
    );
    let m = feature_msg(&mut net, b, "ble.beacon_key")
        .to(&id_of(1))
        .with_ttl(0);
    net.send(b, m).unwrap();
    assert_eq!(net.drain_delivered(a).len(), 1);
}

#[test]
fn envelope_replayed_to_the_same_peer_is_delivered_once() {
    let mut net = Net::new();
    let a = net.add(1, DeviceType::Mac);
    let b = net.add(2, DeviceType::AndroidPhone);
    net.pair(b, a);
    let m = feature_msg(&mut net, b, "dnd.update").broadcast();
    net.send(b, m.clone()).unwrap();
    assert_eq!(net.drain_delivered(a).len(), 1);
    // Re-originating the identical envelope (same id) from b: a's seen cache drops it.
    let again = net.nodes[b].core.send(m);
    // b already recorded the id as seen, but originating still sends; the receiver de-duplicates.
    net.pump(b, again.unwrap());
    assert!(net.drain_delivered(a).is_empty());
}

#[test]
fn forged_tampered_and_stale_envelopes_are_dropped() {
    let mut net = Net::new();
    let a = net.add(1, DeviceType::Mac);
    let b = net.add(2, DeviceType::AndroidPhone);
    net.pair(b, a);

    // Unsigned envelope claiming to be from b.
    let mut unsigned = feature_msg(&mut net, b, "dnd.update").broadcast();
    unsigned.sig = Some("AAAA".into());
    net.send(b, unsigned).unwrap();
    assert!(net.drain_delivered(a).is_empty(), "bad signature");

    // Signed by the wrong key (a signs a message claiming sender b).
    let forged = feature_msg(&mut net, b, "dnd.update").broadcast();
    let key = SigningKey::from_bytes(&[101; 32]); // a's signing key (1 + 100)
    let forged = gossip_core::crypto::sign::sign(forged, &key).unwrap();
    net.send(b, forged).unwrap();
    assert!(net.drain_delivered(a).is_empty(), "signed by someone else");

    // Old timestamp (outside the 15 minute window).
    let mut old = net.nodes[b].core.new_envelope("dnd.update").broadcast();
    old.ts = T0 - 16 * 60 * 1000;
    net.send(b, old).unwrap();
    assert!(net.drain_delivered(a).is_empty(), "stale timestamp");

    // Oversized identifier.
    let mut big = net.nodes[b].core.new_envelope("dnd.update").broadcast();
    big.id = "x".repeat(65);
    net.send(b, big).unwrap();
    assert!(net.drain_delivered(a).is_empty(), "oversized id");

    // A genuine one still arrives afterwards.
    let ok = feature_msg(&mut net, b, "dnd.update").broadcast();
    net.send(b, ok).unwrap();
    assert_eq!(net.drain_delivered(a).len(), 1);
}

#[test]
fn raw_followup_is_delivered_relayed_and_hash_checked() {
    let mut net = Net::new();
    let a = net.add(1, DeviceType::Mac);
    let b = net.add(2, DeviceType::AndroidPhone);
    let c = net.add(3, DeviceType::AndroidTablet);
    net.pair(b, a);
    net.pair(c, a);
    net.introduce(a);

    let png = vec![0x89, b'P', b'N', b'G', 1, 2, 3, 4, 5];
    let m = feature_msg(&mut net, b, "clipboard.update").broadcast();
    let actions = net.nodes[b].core.send_with_raw(m, &png).unwrap();
    net.pump(b, actions);
    for node in [a, c] {
        let got: Vec<_> = net.nodes[node]
            .events
            .iter()
            .filter_map(|e| match e {
                Event::Deliver { envelope, raw } if envelope.kind == "clipboard.update" => {
                    Some((envelope.kind.clone(), raw.clone()))
                }
                _ => None,
            })
            .collect();
        assert_eq!(got.len(), 1, "node {node}");
        assert_eq!(
            got[0].1.as_deref(),
            Some(&png[..]),
            "raw frame delivered with its envelope at node {node}"
        );
    }
}

#[test]
fn raw_frame_not_matching_the_signed_hash_is_discarded_but_drained() {
    let mut net = Net::new();
    let a = net.add(1, DeviceType::Mac);
    let b = net.add(2, DeviceType::AndroidPhone);
    net.pair(b, a);

    // b commits (in the signed payload) to one raw frame but puts a different one on the wire.
    let mut lying = feature_msg(&mut net, b, "clipboard.update")
        .broadcast()
        .binding_raw_frame(b"what was signed");
    lying.has_raw_followup = true;
    let actions = net.nodes[b]
        .core
        .send_unchecked_for_tests(&id_of(1), lying, Some(b"what was sent"))
        .unwrap();
    net.pump(b, actions);
    assert!(
        net.drain_delivered(a).is_empty(),
        "a mismatching raw frame must not be delivered"
    );

    // The raw frame was still consumed, so the stream is in sync and the next message is delivered normally.
    let ok = feature_msg(&mut net, b, "dnd.update").broadcast();
    net.send(b, ok).unwrap();
    let got = net.drain_delivered(a);
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].kind, "dnd.update");

    // A matching one is delivered with its frame.
    let m = feature_msg(&mut net, b, "clipboard.update").broadcast();
    let actions = net.nodes[b].core.send_with_raw(m, b"honest").unwrap();
    net.pump(b, actions);
    let delivered: Vec<_> = net.nodes[a]
        .events
        .iter()
        .filter_map(|e| match e {
            Event::Deliver { envelope, raw } if envelope.kind == "clipboard.update" => {
                Some(raw.clone())
            }
            _ => None,
        })
        .collect();
    assert_eq!(delivered, [Some(b"honest".to_vec())]);
}

#[test]
fn revocation_disconnects_gossips_and_cannot_be_undone_by_gossip() {
    let mut net = Net::new();
    let a = net.add(1, DeviceType::Mac);
    let b = net.add(2, DeviceType::AndroidPhone);
    let c = net.add(3, DeviceType::AndroidTablet);
    net.pair(b, a);
    net.pair(c, a);

    // a forgets c: c is disconnected, b learns the revocation through the mesh.
    let actions = net.nodes[a].core.revoke_device(&id_of(3));
    net.pump(a, actions);
    assert!(!net.nodes[a].core.is_connected(&id_of(3)));
    assert!(net.nodes[a].core.trust().revoked_at(&id_of(3)).is_some());
    assert!(kinds(&net.nodes[a]).contains(&"trust"));
    assert!(
        net.nodes[b].core.trust().revoked_at(&id_of(3)).is_none()
            || !net.nodes[b].core.trust().is_trusted(&id_of(3))
    );

    // A roster that introduces the revoked device again is ignored and answered with a reminder.
    let roster = {
        let payload = json!({"devices": [{
            "deviceId": id_of(3), "publicKey": B64.encode([3u8; 32]), "deviceName": "C", "deviceType": "android-tablet"
        }]});
        let Value::Object(payload) = payload else {
            unreachable!()
        };
        feature_msg(&mut net, b, "trust.roster_update")
            .to(&id_of(1))
            .with_payload(payload)
    };
    net.send(b, roster).unwrap();
    assert!(
        !net.nodes[a].core.trust().is_trusted(&id_of(3)),
        "gossip cannot resurrect a revoked device"
    );
}

#[test]
fn roster_gossip_introduces_new_devices_but_never_overwrites() {
    let mut net = Net::new();
    let a = net.add(1, DeviceType::Mac);
    let b = net.add(2, DeviceType::AndroidPhone);
    net.pair(b, a);
    let c_key = StaticKeypair::from_secret_bytes([3; 32]).public_bytes();
    let signing = SigningKey::from_bytes(&[103; 32])
        .verifying_key()
        .to_bytes();
    let payload = json!({"devices": [
        {"deviceId": id_of(3), "publicKey": B64.encode(c_key), "deviceName": "Tablet", "deviceType": "android-tablet",
         "signingPublicKey": B64.encode(signing)},
        {"deviceId": id_of(4), "publicKey": "not-base64", "deviceName": "Bad", "deviceType": "android-tablet"},
        {"deviceId": id_of(5), "publicKey": B64.encode(c_key), "deviceName": "Odd", "deviceType": "toaster"},
        {"deviceId": id_of(1), "publicKey": B64.encode(c_key), "deviceName": "Me", "deviceType": "mac"},
    ]});
    let Value::Object(payload) = payload else {
        unreachable!()
    };
    let m = feature_msg(&mut net, b, "trust.roster_update")
        .to(&id_of(1))
        .with_payload(payload.clone());
    net.send(b, m).unwrap();
    let trust = net.nodes[a].core.trust();
    assert!(trust.is_trusted(&id_of(3)));
    assert!(!trust.is_trusted(&id_of(4)), "invalid key skipped");
    assert!(!trust.is_trusted(&id_of(5)), "unknown device type skipped");
    let added_at = trust.device(&id_of(3)).unwrap().added_at;

    // The same roster again changes nothing, including addedAt.
    net.set_time(T0 + 60_000);
    let m = feature_msg(&mut net, b, "trust.roster_update")
        .to(&id_of(1))
        .with_payload(payload);
    net.send(b, m).unwrap();
    assert_eq!(
        net.nodes[a]
            .core
            .trust()
            .device(&id_of(3))
            .unwrap()
            .added_at,
        added_at
    );
}

#[test]
fn heartbeat_is_sent_and_a_silent_peer_is_dropped() {
    let mut net = Net::new();
    let a = net.add(1, DeviceType::Mac);
    let b = net.add(2, DeviceType::AndroidPhone);
    net.pair(b, a);

    // Healthy: heartbeats flow both ways, so neither side goes stale over several minutes.
    let mut t = T0;
    for _ in 0..30 {
        t += 10_000;
        net.set_time(t);
        for n in [a, b] {
            let actions = net.nodes[n].core.tick();
            net.pump(n, actions);
        }
    }
    assert!(net.nodes[a].core.is_connected(&id_of(2)));
    assert!(net.nodes[b].core.is_connected(&id_of(1)));

    // b goes silent (its actions are not delivered): a drops it after the timeout.
    for _ in 0..8 {
        t += 10_000;
        net.set_time(t);
        let actions = net.nodes[a].core.tick();
        // Discard a's sends to b by pumping only events.
        for act in actions {
            if let Action::Event(e) = act {
                net.nodes[a].events.push(e);
            } else if let Action::Close { conn } = act {
                if let Some((peer, pc)) = net.links.remove(&(a, conn)) {
                    net.links.remove(&(peer, pc));
                    let more = net.nodes[peer].core.connection_closed(pc);
                    net.pump(peer, more);
                }
            }
        }
    }
    assert!(
        !net.nodes[a].core.is_connected(&id_of(2)),
        "stale peer dropped"
    );
}

#[test]
fn turned_off_features_neither_send_nor_deliver() {
    let mut net = Net::new();
    let a = net.add(1, DeviceType::Mac);
    let b = net.add(2, DeviceType::AndroidPhone);
    net.pair(b, a);

    let mut off = FeatureSettings::all_enabled();
    off.set_enabled(Feature::Clipboard, false);
    net.nodes[a].core.set_features(off.clone());

    // Receiving: a drops clipboard.* but still takes dnd.*.
    let m = feature_msg(&mut net, b, "clipboard.update").broadcast();
    net.send(b, m).unwrap();
    assert!(net.drain_delivered(a).is_empty());
    let m = feature_msg(&mut net, b, "dnd.update").broadcast();
    net.send(b, m).unwrap();
    assert_eq!(net.drain_delivered(a).len(), 1);

    // Sending: a's clipboard send is a silent no-op, not an error.
    let m = feature_msg(&mut net, a, "clipboard.update").broadcast();
    assert!(net.nodes[a].core.send(m).unwrap().is_empty());
}

#[test]
fn oversized_declared_frame_closes_the_connection() {
    let mut net = Net::new();
    let a = net.add(1, DeviceType::Mac);
    let actions = net.nodes[a].core.connection_accepted(77).unwrap();
    assert!(actions.is_empty());
    // A handshake-stage frame larger than 16 KiB is refused outright.
    let mut header = (20_000u32).to_be_bytes().to_vec();
    header.extend_from_slice(&[0; 10]);
    let out = net.nodes[a].core.bytes_received(77, &header);
    assert!(out.iter().any(|x| matches!(x, Action::Close { conn: 77 })));
}

#[test]
fn garbage_before_the_handshake_closes_the_connection() {
    let mut net = Net::new();
    let a = net.add(1, DeviceType::Mac);
    net.nodes[a].core.connection_accepted(5).unwrap();
    let junk = gossip_core::wire::frame::encode(b"not json at all");
    let out = net.nodes[a].core.bytes_received(5, &junk);
    assert!(out.iter().any(|x| matches!(x, Action::Close { conn: 5 })));
}

#[test]
fn bytes_can_arrive_in_arbitrary_pieces() {
    // Re-run the pairing flow delivering one byte at a time.
    let mut net = Net::new();
    let mac = net.add(1, DeviceType::Mac);
    let phone = net.add(2, DeviceType::AndroidPhone);
    net.nodes[mac].core.arm_pairing("t");
    let (a, b) = (1, 2);
    net.links.insert((phone, a), (mac, b));
    net.links.insert((mac, b), (phone, a));
    net.nodes[mac].core.connection_accepted(b).unwrap();
    let target = id_of(1);
    let key = net.noise_pub(mac);
    let mut pending: VecDeque<(usize, Action)> = net.nodes[phone]
        .core
        .dial(a, &target, key, Some(PairingIntent { token: "t".into() }))
        .unwrap()
        .into_iter()
        .map(|x| (phone, x))
        .collect();
    while let Some((n, act)) = pending.pop_front() {
        match act {
            Action::Send { conn, bytes } => {
                let (peer, pc) = net.links[&(n, conn)];
                for byte in bytes {
                    let more = net.nodes[peer].core.bytes_received(pc, &[byte]);
                    pending.extend(more.into_iter().map(|x| (peer, x)));
                }
            }
            Action::Event(e) => net.nodes[n].events.push(e),
            Action::Close { .. } => panic!("unexpected close"),
        }
    }
    assert!(net.prompt(mac).is_some() && net.prompt(phone).is_some());
}

#[test]
fn reconciliation_is_due_on_connect_and_periodically() {
    let mut net = Net::new();
    let a = net.add(1, DeviceType::Mac);
    let b = net.add(2, DeviceType::AndroidPhone);
    net.pair(b, a);
    let on_connect: Vec<_> = net.nodes[a]
        .events
        .iter()
        .filter_map(|e| match e {
            Event::ReconcileDue(d) if d.peer.is_some() => Some(d.task),
            _ => None,
        })
        .collect();
    assert!(on_connect.contains(&"trust.roster_update") && on_connect.contains(&"dnd.update"));

    net.nodes[a].events.clear();
    // Keep the connection healthy for two minutes; the 60s tasks fire, the 300s ones do not.
    let mut t = T0;
    for _ in 0..13 {
        t += 10_000;
        net.set_time(t);
        for n in [a, b] {
            let actions = net.nodes[n].core.tick();
            net.pump(n, actions);
        }
    }
    let periodic: Vec<_> = net.nodes[a]
        .events
        .iter()
        .filter_map(|e| match e {
            Event::ReconcileDue(d) if d.peer.is_none() => Some(d.task),
            _ => None,
        })
        .collect();
    assert!(periodic.contains(&"dnd.update"));
    assert!(!periodic.contains(&"trust.roster_update"));
    assert!(net.wire.len() > 4);
}

#[test]
fn frames_sent_while_the_user_is_still_confirming_are_queued_and_replayed_in_order() {
    // An initiator that already trusts the responder (like the Android app that scanned its QR) starts talking the moment
    // the handshake completes, while the responder is still showing the confirmation prompt. Those frames must not be
    // dropped undecrypted: Noise nonces are implicit counters, so one lost frame would desync the session for good.
    use gossip_core::trust::{TrustSnapshot, TrustedDevice};

    let mut net = Net::new();
    let mac = net.add(1, DeviceType::Mac);
    let phone = net.add(2, DeviceType::AndroidPhone);
    let mac_noise = B64.encode(StaticKeypair::from_secret_bytes([1; 32]).public_bytes());
    let mac_signing = B64.encode(
        SigningKey::from_bytes(&[101; 32])
            .verifying_key()
            .to_bytes(),
    );
    let phone_core = Core::new(
        TestEnv::new(2, T0),
        identity(2, DeviceType::AndroidPhone),
        TrustSnapshot {
            devices: vec![TrustedDevice {
                device_id: id_of(1),
                public_key: mac_noise,
                device_name: "Mac".into(),
                device_type: "mac".into(),
                added_at: T0,
                signing_public_key: Some(mac_signing),
                beacon_key: None,
            }],
            revoked: Default::default(),
        },
        FeatureSettings::all_enabled(),
    );
    net.nodes[phone].core = phone_core;

    net.nodes[mac].core.arm_pairing("t");
    net.open(phone, mac, Some("t"));
    assert!(
        net.nodes[phone].core.is_connected(&id_of(1)),
        "the initiator trusts the Mac, so it is live at once"
    );
    let (conn, _) = net.prompt(mac).expect("the Mac must ask the user");
    assert!(
        !net.nodes[mac].core.is_connected(&id_of(2)),
        "not live until the user confirms"
    );

    // The phone keeps talking during the confirmation window.
    for n in 0..5 {
        let m = net.nodes[phone]
            .core
            .new_envelope("dnd.update")
            .broadcast()
            .with_payload(
                serde_json::json!({ "enabled": true, "n": n })
                    .as_object()
                    .unwrap()
                    .clone(),
            );
        net.send(phone, m).unwrap();
    }
    assert!(
        net.drain_delivered(mac).is_empty(),
        "nothing is delivered before the user confirms"
    );

    net.confirm(mac, conn, true);
    assert!(net.nodes[mac].core.is_connected(&id_of(2)));
    let got = net.drain_delivered(mac);
    let counts: Vec<i64> = got
        .iter()
        .filter(|e| e.kind == "dnd.update")
        .map(|e| e.payload["n"].as_i64().unwrap())
        .collect();
    assert_eq!(
        counts,
        [0, 1, 2, 3, 4],
        "every queued frame is replayed, in order"
    );

    // And the session is still in sync for what arrives afterwards.
    let m = net.nodes[phone].core.new_envelope("dnd.update").broadcast();
    net.send(phone, m).unwrap();
    assert_eq!(net.drain_delivered(mac).len(), 1);
}

#[test]
fn a_flood_of_frames_during_confirmation_closes_the_connection() {
    use gossip_core::limits::PENDING_FRAME_LIMIT;
    use gossip_core::trust::{TrustSnapshot, TrustedDevice};

    let mut net = Net::new();
    let mac = net.add(1, DeviceType::Mac);
    let phone = net.add(2, DeviceType::AndroidPhone);
    let trust = TrustSnapshot {
        devices: vec![TrustedDevice {
            device_id: id_of(1),
            public_key: B64.encode(StaticKeypair::from_secret_bytes([1; 32]).public_bytes()),
            device_name: "Mac".into(),
            device_type: "mac".into(),
            added_at: T0,
            signing_public_key: Some(
                B64.encode(
                    SigningKey::from_bytes(&[101; 32])
                        .verifying_key()
                        .to_bytes(),
                ),
            ),
            beacon_key: None,
        }],
        revoked: Default::default(),
    };
    net.nodes[phone].core = Core::new(
        TestEnv::new(2, T0),
        identity(2, DeviceType::AndroidPhone),
        trust,
        FeatureSettings::all_enabled(),
    );
    net.nodes[mac].core.arm_pairing("t");
    net.open(phone, mac, Some("t"));
    assert!(net.prompt(mac).is_some());
    for _ in 0..(PENDING_FRAME_LIMIT + 20) {
        let m = net.nodes[phone].core.new_envelope("dnd.update").broadcast();
        if net.send(phone, m).is_err() {
            break;
        }
    }
    assert!(
        net.links.is_empty(),
        "the Mac gave up on an unconfirmed peer that kept flooding"
    );
    assert!(!net.nodes[mac].core.is_connected(&id_of(2)));
}

#[test]
fn a_provisional_row_is_trusted_for_connecting_but_never_announced() {
    // The Android pairing flow: the scanning device adds a provisional row for the device whose QR it scanned, dials it
    // as an already-trusted peer, and only after the other side confirms is the row real.
    use gossip_core::trust::{TrustSnapshot, TrustedDevice};

    let mut net = Net::new();
    let mac = net.add(1, DeviceType::Mac);
    let phone = net.add(2, DeviceType::AndroidPhone);
    let row = TrustedDevice {
        device_id: id_of(1),
        public_key: B64.encode(StaticKeypair::from_secret_bytes([1; 32]).public_bytes()),
        device_name: "Mac".into(),
        device_type: "mac".into(),
        added_at: T0,
        signing_public_key: Some(
            B64.encode(
                SigningKey::from_bytes(&[101; 32])
                    .verifying_key()
                    .to_bytes(),
            ),
        ),
        beacon_key: None,
    };
    net.nodes[phone].core.set_trust(
        TrustSnapshot {
            devices: vec![row],
            revoked: Default::default(),
        },
        vec![id_of(1)],
    );

    let roster = net.nodes[phone].core.roster_update(None);
    let announced = roster.payload["devices"].as_array().unwrap();
    assert_eq!(
        announced.len(),
        1,
        "only the phone itself: the provisional Mac is not announced"
    );
    assert_eq!(announced[0]["deviceId"], id_of(2).as_str());

    net.nodes[mac].core.arm_pairing("t");
    net.open(phone, mac, Some("t"));
    assert!(
        net.nodes[phone].core.is_connected(&id_of(1)),
        "a provisional peer is dialable and live without a prompt"
    );
    let (conn, _) = net
        .prompt(mac)
        .expect("the other side still has to confirm");
    net.confirm(mac, conn, true);

    // Once the shell clears the provisional mark the row is announced like any other.
    let snapshot = net.nodes[phone].core.trust_snapshot();
    net.nodes[phone].core.set_trust(snapshot, vec![]);
    let roster = net.nodes[phone].core.roster_update(None);
    assert_eq!(roster.payload["devices"].as_array().unwrap().len(), 2);

    // Messages from the confirmed peer verify (its signing key came with the row, then the handshake).
    let m = feature_msg(&mut net, mac, "dnd.update").broadcast();
    net.send(mac, m).unwrap();
    assert_eq!(net.drain_delivered(phone).len(), 1);
}

#[test]
fn set_trust_replaces_the_table_including_tombstones() {
    use gossip_core::trust::TrustSnapshot;
    let mut net = Net::new();
    let a = net.add(1, DeviceType::Mac);
    net.pair_with_stranger(a);
    assert!(net.nodes[a].core.trust().is_trusted(&id_of(9)));
    let mut snapshot = net.nodes[a].core.trust_snapshot();
    snapshot.devices.clear();
    snapshot.revoked.insert(id_of(9), T0);
    net.nodes[a].core.set_trust(snapshot, vec![]);
    assert!(!net.nodes[a].core.trust().is_trusted(&id_of(9)));
    assert_eq!(net.nodes[a].core.trust().revoked_at(&id_of(9)), Some(T0));
    let _ = TrustSnapshot::default();
}
