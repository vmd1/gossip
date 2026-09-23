# Wire Protocol

This document describes the byte-level framing used on the TCP socket between a paired Mac and Android device, once discovery (mDNS/Bonjour) has located a peer. See `docs/architecture.md` for the broader system picture and `docs/adr/0003-noise-ik-handshake.md` for why `Noise_IK` was chosen.

## Port and reaching a peer off-LAN

Both sides listen on a fixed TCP port, `7913` (`TransportManager.DEFAULT_PORT` on Android, `TransportManager.defaultPort` on Mac) — not an ephemeral one. On-LAN pairing/reconnection still goes through mDNS/Bonjour exactly as this doc's title implies (Bonjour resolves the actual advertised port either way), but the fixed port is also what makes a *manual* connection possible when discovery can't reach the peer at all (different networks, e.g. bridged only by a Tailscale tunnel). Both platforms let the user record a fallback address per trusted device (`TrustedDevice.fallbackHost` — Android's "Paired Devices" screen, Mac's "Trusted Devices" list in the menu bar); while not connected, each side periodically dials that address directly on port 7913, bypassing discovery entirely — `SyncForegroundService.runFallbackDialLoop` on Android, a `Timer` in `ConnectApp.init()` calling `TransportManager.connect(toFallbackHost:remoteStaticKey:)` on Mac. Android is otherwise always the listener (`TransportManager.listen()`) and Mac otherwise always the discoverer/dialer (Bonjour browse + `NWConnection`) — the fallback path is the one case either side dials out manually, outside its normal role.

If the Mac's fixed port is already in use (e.g. a second local instance during development), it falls back to an ephemeral port for that run — on-LAN discovery still works, but the fallback-address dial path won't reach it until it's next started cleanly.

## Framing

Every frame on the socket has the same shape:

```
[4-byte big-endian length][payload]
```

- The 4-byte length prefix is an unsigned big-endian integer giving the length of `payload` in bytes (not including the 4-byte header itself).
- `payload` is `Noise`-encrypted ciphertext (post-handshake transport messages), except for the handshake frames themselves, whose payload is the raw Noise handshake message bytes as defined by the `Noise_IK` pattern.
- Readers must buffer until they have the full 4-byte length, then buffer until they have that many additional bytes, before attempting to process a frame. There is no maximum frame size defined in Wave 1; implementations should apply a sane upper bound (e.g. reject/close on an implausibly large length) as a defensive measure.

## Decrypted plaintext: the JSON envelope

Once a transport frame's ciphertext is decrypted via the established Noise session, the resulting plaintext is a single JSON document matching `schema/envelope.schema.json` — the envelope described in that schema (`v`, `id`, `type`, `senderId`, `recipientId`, `broadcast`, `ts`, `payload`).

- `type` selects the message's meaning and payload shape. See `schema/message-types.md` — the authoritative registry both codebases hand-sync against — for the full list of valid types and their payload fields.
- One decrypted frame carries exactly one envelope (no batching of multiple envelopes into a single frame in Wave 1).

## Large binary payloads (no current message type uses this)

No message type currently carries large binary data (file transfer, the one feature that did, was removed — see below). If a future feature needs to, the convention this codebase previously used is worth keeping:

- The binary bytes are sent as their **own raw frame** (length-prefixed exactly like any other frame, still Noise-encrypted), sent **immediately following** a JSON metadata frame (a normal envelope) that describes what the binary frame contains (e.g. byte length, chunk index, content type, checksum).
- Binary data must **never** be base64-embedded inside a JSON `payload`. Base64 in JSON costs ~33% size overhead and forces full buffering/parsing of large blobs as text; a raw follow-up frame avoids both.

This requires a `sendRawFrame`/one-shot raw-frame-handler primitive alongside the normal envelope `send` — both `TransportManager`s had one (added for file transfer's `file.chunk`), removed along with the feature. Re-add it the same way if needed: a `pendingRawFrameHandler`/equivalent armed synchronously from the metadata envelope's handler, consumed by the very next frame the receive loop reads.
