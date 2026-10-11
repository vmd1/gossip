//! The shared conformance vectors in `schema/`. Every client must reproduce these byte for byte.

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use ed25519_dalek::{SigningKey, VerifyingKey};
use gossip_core::crypto::stream::{End, Profile, StreamCipher};
use gossip_core::crypto::{beacon, sign};
use gossip_core::wire::envelope::Envelope;
use serde_json::Value;
use std::path::PathBuf;

fn schema(name: &str) -> Value {
    // GOSSIP_SCHEMA_DIR lets the same test binary run on a device where the repo checkout does not exist.
    let dir: PathBuf = std::env::var_os("GOSSIP_SCHEMA_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            [env!("CARGO_MANIFEST_DIR"), "..", "..", "schema"]
                .iter()
                .collect()
        });
    let path = dir.join(name);
    serde_json::from_slice(
        &std::fs::read(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display())),
    )
    .unwrap()
}

fn s<'a>(v: &'a Value, k: &str) -> &'a str {
    v[k].as_str()
        .unwrap_or_else(|| panic!("missing string field {k}"))
}

#[test]
fn envelope_signing_vector() {
    let v = schema("envelope-signing-vectors.json");
    let envelope: Envelope = serde_json::from_value(v["envelope"].clone()).unwrap();

    let canonical = sign::signing_bytes(&envelope).unwrap();
    assert_eq!(
        String::from_utf8(canonical).unwrap(),
        s(&v, "canonical"),
        "canonical bytes differ"
    );

    // Seed is bytes 1..=32. The recorded signature came from CryptoKit, whose Ed25519 signing is randomized, so it
    // cannot be reproduced byte for byte; it must verify, and our own (deterministic) signature must verify too.
    let seed: [u8; 32] = std::array::from_fn(|i| i as u8 + 1);
    let key = SigningKey::from_bytes(&seed);
    assert_eq!(
        B64.encode(key.verifying_key().to_bytes()),
        s(&v, "signingPublicKey")
    );
    let ours = sign::sign(envelope.clone(), &key).unwrap();
    assert!(sign::verify(&ours, &key.verifying_key()));

    let public = VerifyingKey::from_bytes(
        &B64.decode(s(&v, "signingPublicKey"))
            .unwrap()
            .try_into()
            .unwrap(),
    )
    .unwrap();
    let mut with_sig = envelope;
    with_sig.sig = Some(s(&v, "signature").to_owned());
    assert!(sign::verify(&with_sig, &public));
    with_sig.ts += 1;
    assert!(
        !sign::verify(&with_sig, &public),
        "tampering must break the signature"
    );
}

#[test]
fn canonical_json_edge_cases() {
    let mut out = Vec::new();
    let value: Value =
        serde_json::from_str(r#"{"b":1,"a":[3.0,-0,"\u0001\u007f"],"é":"x"}"#).unwrap();
    sign::canonical_value(&value, &mut out).unwrap();
    assert_eq!(
        String::from_utf8(out).unwrap(),
        "{\"a\":[3,0,\"\\u0001\u{7f}\"],\"b\":1,\"é\":\"x\"}"
    );

    for bad in ["1.5", "9007199254740993", "1e300", "-9007199254740992"] {
        let mut out = Vec::new();
        let v: Value = serde_json::from_str(bad).unwrap();
        assert!(
            sign::canonical_value(&v, &mut out).is_err(),
            "{bad} should be rejected"
        );
    }
}

fn hex(v: &Value, k: &str) -> Vec<u8> {
    hex::decode(s(v, k)).unwrap()
}

#[test]
fn control_cipher_vectors() {
    let v = schema("control-test-vectors.json");
    let (secret, session) = (hex(&v, "secretHex"), s(&v, "sessionId"));
    // m2d is direction 1, so the Mac (First) seals m2d and the device (Second) seals d2m.
    for case in v["cases"].as_array().unwrap() {
        let counter = case["counter"].as_u64().unwrap();
        let (sender, receiver) = if s(case, "direction") == "m2d" {
            (End::First, End::Second)
        } else {
            (End::Second, End::First)
        };
        let sealer = StreamCipher::new(Profile::CONTROL, &secret, session, sender);
        let sealed = sealer.seal_with_counter(&hex(case, "plaintextHex"), counter);
        assert_eq!(
            hex::encode(&sealed),
            s(case, "sealedHex"),
            "case {}",
            s(case, "name")
        );

        let mut opener = StreamCipher::new(Profile::CONTROL, &secret, session, receiver);
        assert_eq!(
            opener.open(&sealed).unwrap(),
            hex(case, "plaintextHex"),
            "case {}",
            s(case, "name")
        );
        assert!(
            opener.open(&sealed).is_err(),
            "replay of {} must be rejected",
            s(case, "name")
        );
    }
}

#[test]
fn screen_cipher_vectors() {
    let v = schema("screen-cipher-vectors.json");
    let (secret, session) = (hex(&v, "secretHex"), s(&v, "sessionId"));
    for case in v["cases"].as_array().unwrap() {
        let counter = case["counter"].as_u64().unwrap();
        let viewer_sends = case["viewerSends"].as_bool().unwrap();
        let (sender, receiver) = if viewer_sends {
            (End::First, End::Second)
        } else {
            (End::Second, End::First)
        };
        let sealer = StreamCipher::new(Profile::SCREEN, &secret, session, sender);
        let sealed = sealer.seal_with_counter(&hex(case, "plaintextHex"), counter);
        assert_eq!(
            hex::encode(&sealed),
            s(case, "sealedHex"),
            "case {} #{counter}",
            s(case, "name")
        );
        let mut opener = StreamCipher::new(Profile::SCREEN, &secret, session, receiver);
        assert_eq!(opener.open(&sealed).unwrap(), hex(case, "plaintextHex"));
    }
}

#[test]
fn stream_cipher_rejects_tampering_and_wrong_session() {
    let mut a = StreamCipher::new(Profile::SCREEN, &[7; 32], "s1", End::First);
    let mut b = StreamCipher::new(Profile::SCREEN, &[7; 32], "s1", End::Second);
    let mut wrong_session = StreamCipher::new(Profile::SCREEN, &[7; 32], "s2", End::Second);
    let mut wrong_profile = StreamCipher::new(Profile::CONTROL, &[7; 32], "s1", End::Second);
    let sealed = a.seal(b"hello").unwrap();
    assert!(wrong_session.open(&sealed).is_err());
    assert!(wrong_profile.open(&sealed).is_err());
    let mut flipped = sealed.clone();
    *flipped.last_mut().unwrap() ^= 1;
    assert!(b.open(&flipped).is_err());
    // Garbage must not burn the counter: the genuine message still opens.
    assert_eq!(b.open(&sealed).unwrap(), b"hello");
    // A sender never opens its own direction.
    assert!(a.open(&sealed).is_err());
}

#[test]
fn ble_beacon_vectors() {
    let v = schema("ble-beacon-vectors.json");
    let key = hex(&v, "keyHex");
    assert_eq!(v["windowSeconds"].as_u64().unwrap(), beacon::WINDOW_SECONDS);
    for case in v["cases"].as_array().unwrap() {
        let window = case["window"].as_u64().unwrap();
        assert_eq!(
            hex::encode(beacon::tag(&key, window)),
            s(case, "tagHex"),
            "window {window}"
        );
    }
    let now = 12345 * beacon::WINDOW_SECONDS + 5;
    let tags = beacon::acceptable_tags(&key, now);
    assert_eq!(tags[1], beacon::tag(&key, 12345));
    assert_eq!(beacon::seconds_until_next_window(now), 55);
}

// ---- Noise_IK ----------------------------------------------------------------------------------------------

use gossip_core::crypto::noise::{Handshake, NoiseError, StaticKeypair};

fn arr32(v: &Value, k: &str) -> [u8; 32] {
    hex(v, k).try_into().unwrap()
}

#[test]
fn noise_ik_vectors() {
    let v = schema("noise-ik-vectors.json");
    assert_eq!(
        s(&v, "protocolName"),
        gossip_core::crypto::noise::PROTOCOL_NAME
    );
    for case in v["cases"].as_array().unwrap() {
        let name = s(case, "name");
        let i_static = StaticKeypair::from_secret_bytes(arr32(case, "initiatorStaticSecretHex"));
        let r_static = StaticKeypair::from_secret_bytes(arr32(case, "responderStaticSecretHex"));
        assert_eq!(
            i_static.public_bytes().to_vec(),
            hex(case, "initiatorStaticPublicHex"),
            "{name}"
        );
        assert_eq!(
            r_static.public_bytes().to_vec(),
            hex(case, "responderStaticPublicHex"),
            "{name}"
        );

        let mut init = Handshake::initiator(&i_static, r_static.public_bytes(), &[]);
        let mut resp = Handshake::responder(&r_static, &[]);

        let msg1 = init
            .write_message1(
                &hex(case, "message1PayloadHex"),
                arr32(case, "initiatorEphemeralSecretHex"),
            )
            .unwrap();
        assert_eq!(
            hex::encode(&msg1),
            s(case, "message1Hex"),
            "{name}: message 1"
        );
        let p1 = resp.read_message1(&msg1).unwrap();
        assert_eq!(p1, hex(case, "message1PayloadHex"), "{name}");
        assert_eq!(
            resp.remote_static(),
            Some(i_static.public_bytes()),
            "{name}: responder learns initiator key"
        );

        let (msg2, mut resp_t) = resp
            .write_message2(
                &hex(case, "message2PayloadHex"),
                arr32(case, "responderEphemeralSecretHex"),
            )
            .unwrap();
        assert_eq!(
            hex::encode(&msg2),
            s(case, "message2Hex"),
            "{name}: message 2"
        );
        let (p2, mut init_t) = init.read_message2(&msg2).unwrap();
        assert_eq!(p2, hex(case, "message2PayloadHex"), "{name}");
        assert_eq!(
            hex::encode(init_t.handshake_hash()),
            s(case, "handshakeHashHex"),
            "{name}: handshake hash"
        );
        assert_eq!(init_t.handshake_hash(), resp_t.handshake_hash());

        for (n, step) in case["transport"].as_array().unwrap().iter().enumerate() {
            let (sender, receiver) = if s(step, "direction") == "i2r" {
                (&mut init_t, &mut resp_t)
            } else {
                (&mut resp_t, &mut init_t)
            };
            let ct = sender.encrypt(&hex(step, "plaintextHex")).unwrap();
            assert_eq!(
                hex::encode(&ct),
                s(step, "ciphertextHex"),
                "{name}: transport message {n}"
            );
            assert_eq!(
                receiver.decrypt(&ct).unwrap(),
                hex(step, "plaintextHex"),
                "{name}: transport message {n}"
            );
        }
    }
}

#[test]
fn noise_rejects_tampering_and_misuse() {
    let v = schema("noise-ik-vectors.json");
    let case = &v["cases"][0];
    let i_static = StaticKeypair::from_secret_bytes(arr32(case, "initiatorStaticSecretHex"));
    let r_static = StaticKeypair::from_secret_bytes(arr32(case, "responderStaticSecretHex"));
    let msg1 = hex(case, "message1Hex");

    // Every single-byte corruption of message 1 must be rejected (ephemeral, encrypted static, payload, tags).
    for i in 0..msg1.len() {
        let mut bad = msg1.clone();
        bad[i] ^= 0x01;
        let mut resp = Handshake::responder(&r_static, &[]);
        assert!(
            resp.read_message1(&bad).is_err(),
            "flipping byte {i} of message 1 was accepted"
        );
    }
    // Truncations too.
    for len in [0, 31, 32, 79, 80, 95, msg1.len() - 1] {
        let mut resp = Handshake::responder(&r_static, &[]);
        assert!(
            resp.read_message1(&msg1[..len]).is_err(),
            "message 1 truncated to {len} was accepted"
        );
    }
    // The wrong responder key cannot read message 1.
    let other = StaticKeypair::from_secret_bytes([9; 32]);
    assert!(Handshake::responder(&other, &[])
        .read_message1(&msg1)
        .is_err());
    // A different prologue breaks the handshake.
    assert!(Handshake::responder(&r_static, b"x")
        .read_message1(&msg1)
        .is_err());

    // Corrupt message 2.
    let mut init = Handshake::initiator(&i_static, r_static.public_bytes(), &[]);
    init.write_message1(
        &hex(case, "message1PayloadHex"),
        arr32(case, "initiatorEphemeralSecretHex"),
    )
    .unwrap();
    let mut msg2 = hex(case, "message2Hex");
    *msg2.last_mut().unwrap() ^= 1;
    assert_eq!(
        init.read_message2(&msg2).unwrap_err(),
        NoiseError::Decryption
    );

    // Out-of-order use.
    let mut resp = Handshake::responder(&r_static, &[]);
    assert_eq!(
        resp.write_message2(&[], [1; 32]).unwrap_err(),
        NoiseError::WrongState
    );
    let mut init = Handshake::initiator(&i_static, r_static.public_bytes(), &[]);
    assert_eq!(
        init.read_message2(&[0; 64]).unwrap_err(),
        NoiseError::WrongState
    );
    init.write_message1(&[], [3; 32]).unwrap();
    assert_eq!(
        init.write_message1(&[], [3; 32]).unwrap_err(),
        NoiseError::WrongState
    );

    // A low-order ephemeral key (all zeros) is a weak DH result and must be refused.
    let mut weak = vec![0u8; 32];
    weak.extend_from_slice(&msg1[32..]);
    assert_eq!(
        Handshake::responder(&r_static, &[])
            .read_message1(&weak)
            .unwrap_err(),
        NoiseError::WeakKey
    );
}

#[test]
fn noise_failed_decrypt_does_not_desync_session() {
    let v = schema("noise-ik-vectors.json");
    let case = &v["cases"][0];
    let i_static = StaticKeypair::from_secret_bytes(arr32(case, "initiatorStaticSecretHex"));
    let r_static = StaticKeypair::from_secret_bytes(arr32(case, "responderStaticSecretHex"));
    let mut init = Handshake::initiator(&i_static, r_static.public_bytes(), &[]);
    let mut resp = Handshake::responder(&r_static, &[]);
    let m1 = init.write_message1(&[], [1; 32]).unwrap();
    resp.read_message1(&m1).unwrap();
    let (m2, mut rt) = resp.write_message2(&[], [2; 32]).unwrap();
    let (_, mut it) = init.read_message2(&m2).unwrap();

    let good = it.encrypt(b"first").unwrap();
    let mut bad = good.clone();
    bad[0] ^= 1;
    assert!(rt.decrypt(&bad).is_err());
    assert_eq!(
        rt.messages_received(),
        0,
        "a failed decrypt must not advance the nonce"
    );
    assert_eq!(rt.decrypt(&good).unwrap(), b"first");
    assert_eq!(rt.messages_received(), 1);
}
