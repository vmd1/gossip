# Architecture

Gossip is a pair of native applications that let a MacBook and an Android device share state and hand off activity between them, mirroring the feature set of Apple Continuity / Microsoft Phone Link.

## Applications

- **Mac app** — Swift / SwiftUI, runs as a menu-bar app (no dock icon / main window by default). Owns discovery, session management, and renders received state (clipboard, notifications, etc. in later waves) as native UI.
- **Android app** — Kotlin, runs as a foreground service so the connection survives Doze/backgrounding. Owns the equivalent discovery/session/state responsibilities on the Android side.

The two apps share no code or compiler — they are kept in sync purely through the documents in this repo (`schema/message-types.md` above all). Every message type either side sends or handles must be registered there.

## Transport

- **Discovery**: mDNS/Bonjour service advertisement and browsing on the local network. Each device advertises itself with its stable device UUID and basic metadata so the peer can find it without manual IP entry.
- **Connection**: a direct TCP socket between the two devices once discovered, framed per `docs/wire-protocol.md`.
- **Relay fallback**: a WebSocket-based relay for when devices aren't on the same local network is **deferred** — not part of Wave 1 or its immediate successors. The wire protocol and envelope format are relay-agnostic by design so this can be added later without changing message semantics.

## Encrypted sessions

All communication after discovery happens inside a Noise Protocol Framework session using the `Noise_IK` pattern (see `docs/adr/0003-noise-ik-handshake.md`). Pairing is seeded by a QR-code exchange: scanning the QR code transmits the responder's static public key (and enough metadata to locate it on the network) out-of-band, which is what makes the IK pattern viable even on the very first connection between two devices.

- Mac side: Apple CryptoKit (`Curve25519.KeyAgreement`, `ChaChaPoly`, `Curve25519.Signing`).
- Android side: Google Tink (X25519, XChaCha20-Poly1305, Ed25519).

## Device-group trust model

Every device participating in Gossip — Mac or Android, phone or tablet — has:

- a stable, randomly generated **device UUID**, and
- an **Ed25519/X25519 identity keypair** generated on first launch and never transmitted in the clear.

Pairing (via the QR-code flow above) adds an entry to a local **`TrustedDevices` table** on each device: `deviceId → publicKey → metadata` (device name, device type, last-seen timestamp, etc). Sessions are established and messages are authenticated against entries in this table — the protocol never hardcodes "the other device" as a singleton peer.

This was a deliberate design choice, not incidental generality, and the multi-device "ecosystem" it was built for is no longer just future work: this repo now ships mesh support — multiple phones/tablets and a Mac all trusting each other as a group, Android↔Android pairing and reconnect (not just Mac-initiated), and `trust.roster_update` gossip that propagates a new pairing transitively through the whole mesh via the multi-hop flood-forward every device applies to broadcast envelopes (see `docs/wire-protocol.md`'s "Multi-hop relay" section). This is exactly why every wire envelope has carried `senderId`/`recipientId`/`broadcast` from Wave 1 onward — the protocol never hardcoded "the other device" as a singleton peer, so the mesh didn't require a wire-protocol rewrite to add. See `docs/adr/0002-device-group-addressing.md` for the full rationale, and `schema/envelope.schema.json` for the envelope shape.

## Related documents

- `schema/envelope.schema.json` — the wire envelope schema.
- `schema/message-types.md` — the message type registry (source of truth for `type` values).
- `docs/wire-protocol.md` — byte-level framing over the socket.
- `docs/adr/` — architecture decision records for the choices summarized above.
