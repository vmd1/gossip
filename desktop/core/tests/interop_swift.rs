//! Interoperability with the Mac app's real code: the actual `NoiseSession.swift`, `Envelope.swift` and
//! `EnvelopeSigning.swift`, compiled into a small harness (`desktop/scripts/build-swift-interop.sh`). This is a
//! stronger check than shared vectors because nothing about the Swift side is re-derived from a spec.
//!
//! Skipped (with a note) when the harness has not been built, e.g. on non-macOS machines.

use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

use ed25519_dalek::SigningKey;
use gossip_core::crypto::noise::{Handshake, StaticKeypair};
use gossip_core::crypto::sign;
use gossip_core::wire::envelope::Envelope;
use serde_json::json;

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
        assert!(
            !reply.starts_with("ERR"),
            "swift harness: {reply} (for `{}`)",
            &line[..line.len().min(60)]
        );
        reply
    }
}

impl Drop for Swift {
    fn drop(&mut self) {
        let _ = self.child.kill();
    }
}

fn h(b: &[u8]) -> String {
    hex::encode(b)
}

const IDENTITY: &[u8] = br#"{"deviceId":"11111111-1111-1111-1111-111111111111","deviceName":"Interop","deviceType":"mac","signingPublicKey":"ebVWLo/mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ="}"#;

/// Messages of assorted sizes in both directions after the handshake, including one far above 64 KiB (the apps
/// carry clipboard images in single transport frames).
fn exchange_transport(swift: &mut Swift, rust: &mut gossip_core::crypto::noise::Transport) {
    let sizes = [0usize, 1, 15, 16, 17, 1000, 65_535, 65_536, 1 << 20];
    for (i, size) in sizes.iter().enumerate() {
        let msg: Vec<u8> = (0..*size).map(|n| (n * 7 + i) as u8).collect();
        let ct = rust.encrypt(&msg).unwrap();
        assert_eq!(
            swift.cmd(&format!("DEC {}", h(&ct))),
            h(&msg),
            "rust -> swift, {size} bytes"
        );
        let ct = hex::decode(swift.cmd(&format!("ENC {}", h(&msg)))).unwrap();
        assert_eq!(
            rust.decrypt(&ct).unwrap(),
            msg,
            "swift -> rust, {size} bytes"
        );
    }
}

#[test]
fn swift_initiator_rust_responder() {
    let Some(mut swift) = Swift::start() else {
        return;
    };
    let swift_static = StaticKeypair::from_secret_bytes([0x21; 32]);
    let rust_static = StaticKeypair::from_secret_bytes([0x42; 32]);

    swift.cmd(&format!(
        "INIT {} {}",
        h(&swift_static.secret_bytes()),
        h(&rust_static.public_bytes())
    ));
    let msg1 = hex::decode(swift.cmd(&format!("M1 {}", h(IDENTITY)))).unwrap();

    let mut hs = Handshake::responder(&rust_static, &[]);
    assert_eq!(
        hs.read_message1(&msg1).unwrap(),
        IDENTITY,
        "Rust must read what the Mac app's initiator wrote"
    );
    assert_eq!(hs.remote_static(), Some(swift_static.public_bytes()));
    let (msg2, mut transport) = hs.write_message2(b"{\"reply\":true}", [7; 32]).unwrap();

    assert_eq!(
        swift.cmd(&format!("R2 {}", h(&msg2))),
        h(b"{\"reply\":true}"),
        "the Mac app must read Rust's message 2"
    );
    assert_eq!(swift.cmd("PEER"), h(&rust_static.public_bytes()));
    exchange_transport(&mut swift, &mut transport);
}

#[test]
fn rust_initiator_swift_responder() {
    let Some(mut swift) = Swift::start() else {
        return;
    };
    let swift_static = StaticKeypair::from_secret_bytes([0x33; 32]);
    let rust_static = StaticKeypair::from_secret_bytes([0x55; 32]);

    swift.cmd(&format!("RESP {}", h(&swift_static.secret_bytes())));
    let mut hs = Handshake::initiator(&rust_static, swift_static.public_bytes(), &[]);
    let msg1 = hs.write_message1(IDENTITY, [9; 32]).unwrap();

    assert_eq!(
        swift.cmd(&format!("R1 {}", h(&msg1))),
        h(IDENTITY),
        "the Mac app must read Rust's message 1"
    );
    assert_eq!(swift.cmd("PEER"), h(&rust_static.public_bytes()));
    let msg2 = hex::decode(swift.cmd(&format!("M2 {}", h(b"ack-payload")))).unwrap();

    let (payload, mut transport) = hs.read_message2(&msg2).unwrap();
    assert_eq!(
        payload, b"ack-payload",
        "Rust must read what the Mac app's responder wrote"
    );
    exchange_transport(&mut swift, &mut transport);
}

fn envelopes() -> Vec<Envelope> {
    let payloads = [
        json!({}),
        json!({"title": "Héllo \"q\" \\ back\nnew\ttab é 日本 😀", "n": 9007199254740991i64, "neg": -7, "z": 0}),
        json!({"b": [1, -2, 0, true, false, null, {"z": 1, "a": []}], "a": {"y": {"x": [[]]}}, "id": "x/y"}),
        json!({"ctrl": "\u{1}\u{8}\u{c}\u{1f}\u{7f}", "emoji": "👩‍👩‍👧‍👦", "key é": 1, "key a": 2}),
    ];
    let mut out = Vec::new();
    for (i, p) in payloads.into_iter().enumerate() {
        let serde_json::Value::Object(map) = p else {
            unreachable!()
        };
        let mut e = Envelope::new(
            format!("00000000-0000-0000-0000-00000000000{i}"),
            "notification.posted",
            "11111111-1111-1111-1111-111111111111",
            1_759_500_000_123 + i as i64,
        )
        .with_payload(map);
        match i % 3 {
            0 => e = e.broadcast(),
            1 => e = e.to("22222222-2222-2222-2222-222222222222"),
            _ => e.has_raw_followup = true,
        }
        out.push(e);
    }
    out
}

#[test]
fn envelopes_and_signatures_interoperate_with_the_mac_app() {
    let Some(mut swift) = Swift::start() else {
        return;
    };
    let seed = [0x61u8; 32];
    let key = SigningKey::from_bytes(&seed);
    let public_hex = h(&key.verifying_key().to_bytes());

    for e in envelopes() {
        let json = String::from_utf8(e.encode()).unwrap();

        // Swift must accept Rust's JSON, and derive exactly the bytes Rust signs.
        assert_eq!(
            swift.cmd(&format!("CANON {json}")),
            h(&sign::signing_bytes(&e).unwrap()),
            "canonical bytes for {}",
            e.id
        );

        // Rust signs, Swift verifies.
        let signed = sign::sign(e.clone(), &key).unwrap();
        let signed_json = String::from_utf8(signed.encode()).unwrap();
        assert_eq!(
            swift.cmd(&format!("VERIFY {public_hex} {signed_json}")),
            "true",
            "Swift verifies Rust's signature on {}",
            e.id
        );

        // Swift signs, Rust decodes (Swift omits nil fields; Rust must cope) and verifies.
        let swift_signed = swift.cmd(&format!("SIGN {} {json}", h(&seed)));
        let decoded =
            Envelope::decode(swift_signed.as_bytes()).expect("Rust decodes Swift's envelope JSON");
        assert_eq!(decoded.payload, e.payload);
        assert_eq!(decoded.recipient_id, e.recipient_id);
        assert!(
            sign::verify(&decoded, &key.verifying_key()),
            "Rust verifies Swift's signature on {}",
            e.id
        );

        // A tampered copy fails on both sides.
        let mut tampered = signed.clone();
        tampered.ts += 1;
        let tampered_json = String::from_utf8(tampered.encode()).unwrap();
        assert_eq!(
            swift.cmd(&format!("VERIFY {public_hex} {tampered_json}")),
            "false"
        );
        assert!(!sign::verify(&tampered, &key.verifying_key()));
    }
}
