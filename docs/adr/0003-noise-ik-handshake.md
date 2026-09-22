# 0003: Noise_IK Handshake

## Status

Accepted.

## Context

Connect needs an encrypted, mutually-authenticated session between a Mac and an Android device before any application data is exchanged. The Noise Protocol Framework offers several handshake patterns; the two candidates considered were `Noise_XX` (neither party's static key known in advance; keys are exchanged and authenticated during the handshake) and `Noise_IK` (the initiator knows the responder's static public key ahead of time and transmits its own static key, encrypted, in the first message).

Connect's pairing flow already scans a QR code to establish a connection: the QR code payload transmits the responder's static public key (and connection metadata) out-of-band, outside the Noise handshake itself. This out-of-band key distribution is exactly the precondition `Noise_IK` requires to be secure even on a first-ever connection between two devices — `XX` is typically preferred specifically because it doesn't require this precondition, which Connect already satisfies by construction.

## Decision

Use `Noise_IK` for all Connect handshakes — both the very first pairing handshake and every subsequent reconnect — rather than `Noise_XX`.

Reasons:

- The QR-code pairing flow already transmits the responder's static public key out-of-band, so `IK`'s precondition is met from the first connection; there's no window where `XX`'s "unknown responder key" handling would actually be exercised.
- Using a single handshake pattern for both first-pairing and reconnects simplifies the crypto surface: one handshake state machine, one code path, one set of message types (`handshake.hello` / `handshake.ack`, see `schema/message-types.md`) to implement and test on both sides, instead of branching between an initial `XX`-style pairing handshake and a subsequent `IK`/`KK`-style resumption handshake.
- `IK` reaches an authenticated, encrypted state in fewer round trips than `XX`, since the initiator's identity is transmitted (encrypted) in the first message rather than negotiated across additional round trips.

## Implementation

- **Mac**: Apple CryptoKit — `Curve25519.KeyAgreement` for the X25519 DH operations, `ChaChaPoly` for AEAD, `Curve25519.Signing` for the Ed25519 identity keypair used to authenticate device identity at pairing time.
- **Android**: Google Tink — X25519 for DH, XChaCha20-Poly1305 for AEAD, Ed25519 for the identity keypair.

Both sides implement the same `Noise_IK` pattern independently (no shared crypto code), so the exact message structure of `handshake.hello`/`handshake.ack` in `schema/message-types.md` is the contract that keeps the two implementations interoperable.

## Consequences

- If a responder's static public key is ever rotated without a fresh QR-code re-pair, `IK` handshakes from devices still holding the old key will fail closed (as intended) rather than falling back to an `XX`-style negotiation — key rotation is expected to always go through the pairing/QR flow.
- Should Connect ever need to support establishing trust without any out-of-band channel (e.g. some future discovery mode with no QR step), this decision would need to be revisited in favor of `XX` or a hybrid approach for that specific flow.
