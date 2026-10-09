//! Instant Hotspot GATT contract and lock-on-leave: unit tests, plus interop with the Mac app's real
//! `HotspotGattProtocol.swift` (skipped when the Swift harness is not built).

use std::collections::HashSet;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use ed25519_dalek::SigningKey;
use gossip_core::crypto::noise::StaticKeypair;
use gossip_core::features::hotspot_gatt::*;
use gossip_core::features::lock_on_leave::{LockOnLeave, COOLDOWN_MS};

fn signing(seed: u8) -> (SigningKey, String) {
    let k = SigningKey::from_bytes(&[seed; 32]);
    let pk = B64.encode(k.verifying_key().to_bytes());
    (k, pk)
}

#[test]
fn request_is_signed_fresh_and_tamper_evident() {
    let (key, pk) = signing(5);
    let req = ToggleRequest::create(
        "11111111-1111-1111-1111-111111111111",
        true,
        "nonce-1",
        1_000_000,
        &key,
    );
    assert!(req.is_signature_valid(&pk));
    assert!(
        !req.is_signature_valid(&signing(6).1),
        "another device's key"
    );
    for tampered in [
        ToggleRequest {
            en: false,
            ..req.clone()
        },
        ToggleRequest {
            n: "nonce-2".into(),
            ..req.clone()
        },
        ToggleRequest {
            t: req.t + 1,
            ..req.clone()
        },
        ToggleRequest {
            id: "someone-else".into(),
            ..req.clone()
        },
    ] {
        assert!(!tampered.is_signature_valid(&pk), "{tampered:?}");
    }
    assert!(req.is_fresh(1_000_000 + REQUEST_FRESHNESS_MS));
    assert!(!req.is_fresh(1_000_000 + REQUEST_FRESHNESS_MS + 1));
    assert!(
        !req.is_fresh(1_000_000 - REQUEST_FRESHNESS_MS - 1),
        "a request from the future is no fresher"
    );
    assert_eq!(ToggleRequest::decode(&req.encode()), Some(req));
    assert_eq!(
        ToggleRequest::decode(b"{\"id\":\"x\"}"),
        None,
        "a request without t or s is refused"
    );
}

#[test]
fn status_credentials_round_trip_and_are_bound_to_the_signature() {
    let (provider_key, provider_pk) = signing(7);
    let (a, b) = (
        StaticKeypair::from_secret_bytes([1; 32]),
        StaticKeypair::from_secret_bytes([2; 32]),
    );
    let k_ab = derive_shared_secret_key(a.secret_bytes(), b.public_bytes()).unwrap();
    let k_ba = derive_shared_secret_key(b.secret_bytes(), a.public_bytes()).unwrap();
    assert_eq!(k_ab, k_ba, "either side derives the same key");

    let status = Status::create(
        "prov",
        true,
        "n1",
        &provider_key,
        Some(("My SSID", "p@ss \"word\"", &k_ab, [9; 12])),
    );
    assert!(status.is_signature_valid(&provider_pk));
    assert_eq!(
        status.decrypt_credentials(&k_ba),
        Some(("My SSID".to_owned(), "p@ss \"word\"".to_owned()))
    );
    assert_eq!(status.decrypt_credentials(&[0; 32]), None, "wrong key");
    let mut swapped = status.clone();
    swapped.cred = Status::create(
        "prov",
        true,
        "n1",
        &provider_key,
        Some(("Other", "x", &k_ab, [8; 12])),
    )
    .cred;
    assert!(
        !swapped.is_signature_valid(&provider_pk),
        "the signature covers the ciphertext"
    );
    let mut flipped = status.clone();
    flipped.ok = false;
    assert!(!flipped.is_signature_valid(&provider_pk));
    let no_cred = Status::create("prov", false, "n2", &provider_key, None);
    assert!(no_cred.is_signature_valid(&provider_pk) && no_cred.cred.is_none());
    assert_eq!(Status::decode(&status.encode()), Some(status));
    assert_eq!(
        derive_shared_secret_key([1; 32], [0; 32]),
        None,
        "a low-order peer key yields no key"
    );
}

#[test]
fn chunking_round_trips_and_caps_message_size() {
    for len in [0usize, 1, 18, 19, 20, 38, 39, 500, MAX_MESSAGE_BYTES] {
        let msg: Vec<u8> = (0..len).map(|i| i as u8).collect();
        let chunks = encode_chunks(&msg);
        assert!(
            chunks.iter().all(|c| c.len() <= CHUNK_PAYLOAD_SIZE + 1),
            "{len}"
        );
        let mut r = ChunkReassembler::new();
        let mut out = None;
        for c in &chunks {
            out = r.feed(c);
        }
        assert_eq!(out, Some(msg), "len {len}");
    }
    // Oversized: discarded, remaining chunks included, and the reassembler recovers for the next message.
    let big = vec![7u8; MAX_MESSAGE_BYTES + 1];
    let mut r = ChunkReassembler::new();
    let results: Vec<_> = encode_chunks(&big).iter().map(|c| r.feed(c)).collect();
    assert!(results.iter().all(Option::is_none));
    assert_eq!(r.feed(&[FLAG_LAST_CHUNK, 1, 2, 3]), Some(vec![1, 2, 3]));
    assert_eq!(ChunkReassembler::new().feed(&[]), None);
}

#[test]
fn request_gate_rate_limits_addresses_and_rejects_replays() {
    let mut g = RequestGate::new();
    for i in 0..6 {
        assert!(g.allow_rate("aa:bb", i * 1000), "request {i}");
    }
    assert!(
        !g.allow_rate("aa:bb", 10_000),
        "the seventh inside a minute"
    );
    assert!(
        g.allow_rate("cc:dd", 10_000),
        "another address has its own budget"
    );
    assert!(g.allow_rate("aa:bb", 61_000), "the window slides");
    assert!(g.first_use("n1") && !g.first_use("n1"));
    for i in 0..300 {
        g.first_use(&format!("fill-{i}"));
    }
    assert!(g.first_use("n1"), "the bounded set forgot the oldest nonce");
    // Address table is bounded: new addresses are refused once 64 are tracked and none have expired.
    let mut full = RequestGate::new();
    for i in 0..64 {
        assert!(full.allow_rate(&format!("a{i}"), 0));
    }
    assert!(!full.allow_rate("one-too-many", 1000));
    assert!(
        full.allow_rate("one-too-many", 100_000),
        "stale entries are reclaimed"
    );
}

#[test]
fn lock_on_leave_fires_once_per_transition_with_a_cooldown() {
    let set = |ids: &[&str]| ids.iter().map(|s| (*s).to_owned()).collect::<HashSet<_>>();
    let armed = |_: &str| true;
    let mut l = LockOnLeave::new(set(&["phone"]));
    assert!(l.nearby_changed(set(&[]), 0, true, armed), "the phone left");
    assert!(
        !l.nearby_changed(set(&[]), 1_000, true, armed),
        "still away: not a new transition"
    );
    assert!(
        !l.nearby_changed(set(&["phone"]), 2_000, true, armed),
        "coming back never locks"
    );
    assert!(
        !l.nearby_changed(set(&[]), 3_000, true, armed),
        "flapping inside the cooldown must not re-lock an unlocked screen"
    );
    l.nearby_changed(set(&["phone"]), 4_000, true, armed);
    assert!(
        l.nearby_changed(set(&[]), COOLDOWN_MS, true, armed),
        "after the cooldown it may lock again"
    );

    let mut off = LockOnLeave::new(set(&["phone"]));
    assert!(
        !off.nearby_changed(set(&[]), 0, false, armed),
        "the feature toggle is off"
    );
    let mut unarmed = LockOnLeave::new(set(&["phone"]));
    assert!(
        !unarmed.nearby_changed(set(&[]), 0, true, |_| false),
        "the device did not arm lock-on-leave"
    );
    let mut two = LockOnLeave::new(set(&["a", "b"]));
    assert!(
        two.nearby_changed(set(&["b"]), 0, true, |d| d == "a"),
        "only an armed device that left counts"
    );
}

// ---- Interop with the Mac app's HotspotGattProtocol.swift -----------------------------------------------------

struct Swift {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
}

impl Swift {
    fn start() -> Option<Self> {
        let path: PathBuf = [
            env!("CARGO_MANIFEST_DIR"),
            "..",
            "target",
            "interop",
            "swift-harness",
        ]
        .iter()
        .collect();
        if !path.exists() {
            eprintln!(
                "skipping: build the Swift harness with desktop/scripts/build-swift-interop.sh"
            );
            return None;
        }
        let mut child = Command::new(path)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .ok()?;
        let stdin = child.stdin.take()?;
        let stdout = BufReader::new(child.stdout.take()?);
        Some(Self {
            child,
            stdin,
            stdout,
        })
    }

    fn cmd(&mut self, line: &str) -> String {
        writeln!(self.stdin, "{line}").unwrap();
        self.stdin.flush().unwrap();
        let mut reply = String::new();
        self.stdout.read_line(&mut reply).unwrap();
        let reply = reply.trim().to_owned();
        assert!(!reply.starts_with("ERR"), "swift harness: {reply}");
        reply
    }
}

impl Drop for Swift {
    fn drop(&mut self) {
        let _ = self.child.kill();
    }
}

#[test]
fn hotspot_gatt_interoperates_with_the_mac_app() {
    let Some(mut swift) = Swift::start() else {
        return;
    };
    let (key, pk) = signing(0x31);
    let seed_hex = hex::encode([0x31u8; 32]);
    let id = "11111111-1111-1111-1111-111111111111";

    // Shared key: both sides derive the same bytes from the same X25519 identities.
    let (a, b) = (
        StaticKeypair::from_secret_bytes([0x41; 32]),
        StaticKeypair::from_secret_bytes([0x42; 32]),
    );
    let rust_key = derive_shared_secret_key(a.secret_bytes(), b.public_bytes()).unwrap();
    assert_eq!(
        swift.cmd(&format!(
            "HSKEY {} {}",
            hex::encode(a.secret_bytes()),
            hex::encode(b.public_bytes())
        )),
        hex::encode(rust_key)
    );

    // Requests, both directions.
    let req = ToggleRequest::create(id, true, "rust-nonce", 1_760_000_000_000, &key);
    let json = String::from_utf8(req.encode()).unwrap();
    assert_eq!(
        swift.cmd(&format!("HSREQ_VERIFY {pk} {json}")),
        "true",
        "Swift verifies Rust's request"
    );
    let swift_json = swift.cmd(&format!("HSREQ_CREATE {seed_hex} {id} false"));
    let decoded =
        ToggleRequest::decode(swift_json.as_bytes()).expect("Rust decodes Swift's request");
    assert!(
        decoded.is_signature_valid(&pk),
        "Rust verifies Swift's request"
    );
    assert!(!decoded.en && decoded.id == id);

    // Status with encrypted credentials, both directions.
    let status = Status::create(
        id,
        true,
        "n-1",
        &key,
        Some(("Café Wi-Fi", "pässwörd \"q\"", &rust_key, [3; 12])),
    );
    let status_json = String::from_utf8(status.encode()).unwrap();
    assert_eq!(
        swift.cmd(&format!(
            "HSSTATUS_VERIFY {pk} {} {status_json}",
            hex::encode(rust_key)
        )),
        "true Café Wi-Fi pässwörd \"q\"",
        "Swift verifies and decrypts Rust's status"
    );
    let swift_status = swift.cmd(&format!(
        "HSSTATUS_CREATE {seed_hex} {id} true n-2 {} Net pw123",
        hex::encode(rust_key)
    ));
    let from_swift = Status::decode(swift_status.as_bytes()).expect("Rust decodes Swift's status");
    assert!(from_swift.is_signature_valid(&pk));
    assert_eq!(
        from_swift.decrypt_credentials(&rust_key),
        Some(("Net".to_owned(), "pw123".to_owned()))
    );

    // Chunking.
    for len in [0usize, 1, 19, 20, 300] {
        let msg: Vec<u8> = (0..len).map(|i| (i * 3) as u8).collect();
        let swift_chunks = swift.cmd(&format!("HSCHUNKS {}", hex::encode(&msg)));
        let rust_chunks: Vec<String> = encode_chunks(&msg).iter().map(hex::encode).collect();
        assert_eq!(
            swift_chunks,
            rust_chunks.join(","),
            "chunking for {len} bytes"
        );
        let reassembled = swift.cmd(&format!("HSREASSEMBLE {}", rust_chunks.join(",")));
        assert_eq!(
            reassembled,
            hex::encode(&msg),
            "Swift reassembles Rust's chunks ({len})"
        );
    }
}
