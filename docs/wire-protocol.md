# Wire Protocol

This document describes the byte-level framing used on the TCP socket between a paired Mac and Android device, once discovery (mDNS/Bonjour) has located a peer. See `docs/architecture.md` for the broader system picture and `docs/adr/0003-noise-ik-handshake.md` for why `Noise_IK` was chosen.

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

## Large binary payloads (future waves, not in scope now)

Wave 1 has no message types that carry large binary data. When features that do (file transfer chunks, screen-mirroring frames, etc.) are added in later waves, the convention is:

- The binary bytes are sent as their **own raw frame** (length-prefixed exactly like any other frame, still Noise-encrypted), sent **immediately following** a JSON metadata frame (a normal envelope) that describes what the binary frame contains (e.g. byte length, chunk index, content type, checksum).
- Binary data must **never** be base64-embedded inside a JSON `payload`. Base64 in JSON costs ~33% size overhead and forces full buffering/parsing of large blobs as text; a raw follow-up frame avoids both.

This convention is recorded here now so that any future message type introducing binary payloads has an established pattern to follow, rather than each feature inventing its own.
