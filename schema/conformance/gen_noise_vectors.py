#!/usr/bin/env python3
"""Generates schema/noise-ik-vectors.json with an implementation independent of both apps.

Mac (CryptoKit) and Android (javax.crypto) each hand-roll Noise_IK; neither is a trustworthy oracle for the other.
This uses the third-party `noiseprotocol` package (pip install noiseprotocol) with fixed key material so every
client, and the Rust core, can be checked byte for byte. Re-run only to add cases: changing existing vectors would
mean the wire format changed.

    python3 schema/conformance/gen_noise_vectors.py > schema/noise-ik-vectors.json
"""
import json
import sys

from noise.connection import Keypair, NoiseConnection

PROTOCOL = b"Noise_IK_25519_ChaChaPoly_SHA256"


def key(seed: int) -> bytes:
    """Deterministic 32-byte secret: seed, seed+1, ..."""
    return bytes((seed + i) & 0xFF for i in range(32))


def public_of(secret: bytes) -> bytes:
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
    from cryptography.hazmat.primitives import serialization as s

    return X25519PrivateKey.from_private_bytes(secret).public_key().public_bytes(s.Encoding.Raw, s.PublicFormat.Raw)


def make_case(name, i_static, r_static, i_eph, r_eph, p1, p2, transport):
    r_pub = public_of(r_static)
    init = NoiseConnection.from_name(PROTOCOL)
    init.set_as_initiator()
    init.set_keypair_from_private_bytes(Keypair.STATIC, i_static)
    init.set_keypair_from_public_bytes(Keypair.REMOTE_STATIC, r_pub)
    init.set_keypair_from_private_bytes(Keypair.EPHEMERAL, i_eph)
    init.start_handshake()

    resp = NoiseConnection.from_name(PROTOCOL)
    resp.set_as_responder()
    resp.set_keypair_from_private_bytes(Keypair.STATIC, r_static)
    resp.set_keypair_from_private_bytes(Keypair.EPHEMERAL, r_eph)
    resp.start_handshake()

    msg1 = init.write_message(p1)
    assert resp.read_message(msg1) == p1
    msg2 = resp.write_message(p2)
    assert init.read_message(msg2) == p2
    assert init.handshake_finished and resp.handshake_finished
    assert init.get_handshake_hash() == resp.get_handshake_hash()

    steps = []
    for direction, plaintext in transport:
        sender, receiver = (init, resp) if direction == "i2r" else (resp, init)
        ct = sender.encrypt(plaintext)
        assert receiver.decrypt(ct) == plaintext
        steps.append({"direction": direction, "plaintextHex": plaintext.hex(), "ciphertextHex": ct.hex()})

    return {
        "name": name,
        "initiatorStaticSecretHex": i_static.hex(),
        "responderStaticSecretHex": r_static.hex(),
        "responderStaticPublicHex": r_pub.hex(),
        "initiatorStaticPublicHex": public_of(i_static).hex(),
        "initiatorEphemeralSecretHex": i_eph.hex(),
        "responderEphemeralSecretHex": r_eph.hex(),
        "message1PayloadHex": p1.hex(),
        "message2PayloadHex": p2.hex(),
        "message1Hex": msg1.hex(),
        "message2Hex": msg2.hex(),
        "handshakeHashHex": init.get_handshake_hash().hex(),
        "transport": steps,
    }


IDENTITY1 = (
    b'{"deviceId":"11111111-1111-1111-1111-111111111111","deviceName":"Test Mac","deviceType":"mac",'
    b'"signingPublicKey":"ebVWLo/mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ=","pairingToken":"tok-123"}'
)
IDENTITY2 = (
    b'{"deviceId":"22222222-2222-2222-2222-222222222222","deviceName":"Test Phone","deviceType":"android-phone",'
    b'"signingPublicKey":"ebVWLo/mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ="}'
)

cases = [
    make_case(
        "identity_payloads",
        key(1), key(33), key(65), key(97),
        IDENTITY1, IDENTITY2,
        [("i2r", b'{"hello":"world"}'), ("r2i", b"{}"), ("i2r", b"second"), ("r2i", b"\x00\x01\x02\xff"), ("i2r", b"")],
    ),
    make_case("empty_payloads", key(3), key(35), key(67), key(99), b"", b"", [("i2r", b"x"), ("r2i", b"y")]),
    make_case(
        "large_payloads",
        key(5), key(37), key(69), key(101),
        bytes(range(256)) * 4, bytes(range(255, -1, -1)) * 3,
        [("i2r", bytes((i * 7) & 0xFF for i in range(4000))), ("r2i", b"\xaa" * 1000)],
    ),
]

json.dump(
    {
        "description": (
            "Noise_IK_25519_ChaChaPoly_SHA256 vectors with fixed static and ephemeral keys, generated with the "
            "independent 'noiseprotocol' Python package (schema/conformance/gen_noise_vectors.py). Standard Noise: "
            "empty prologue, IETF ChaCha20-Poly1305 with a 4-zero-byte + LE64 nonce, HMAC-SHA256 HKDF. Initiator "
            "writes message1, responder reads it and writes message2; 'transport' alternates directions from "
            "counter 0. Any change to these values is a wire break."
        ),
        "protocolName": PROTOCOL.decode(),
        "cases": cases,
    },
    sys.stdout,
    indent=2,
)
print()
