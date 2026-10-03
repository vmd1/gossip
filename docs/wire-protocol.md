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
- Readers must buffer until they have the full 4-byte length, then buffer until they have that many additional bytes, before attempting to process a frame. Readers must enforce a maximum: **16 KiB** for the two handshake frames (before the peer is authenticated) and **16 MiB** for transport frames; a larger declared length closes the connection. Implementations also bound the number of simultaneous not-yet-handshaken inbound connections (32 total, 4 per source address) and must not allocate a declared frame length up front. After the handshake, a peer that is already trusted must have presented the same Noise static key it was paired with; a different key closes the connection.

## Decrypted plaintext: the JSON envelope

Once a transport frame's ciphertext is decrypted via the established Noise session, the resulting plaintext is a single JSON document matching `schema/envelope.schema.json` — the envelope described in that schema (`v`, `id`, `type`, `senderId`, `recipientId`, `broadcast`, `ts`, `payload`).

- `type` selects the message's meaning and payload shape. See `schema/message-types.md` — the authoritative registry both codebases hand-sync against — for the full list of valid types and their payload fields.
- One decrypted frame carries exactly one envelope (no batching of multiple envelopes into a single frame in Wave 1).

## Frames before trust confirmation

A responder sends `handshake.ack` before an untrusted initiator has been confirmed by the user, so the initiator may send transport frames (roster, initial syncs) during that window. Noise transport nonces are implicit counters, so a responder must never discard those frames undecrypted: it holds them (bounded, 256 frames; closes the connection if exceeded) and decrypts/routes them in arrival order once the peer is confirmed and promoted, or drops them with the connection if the user declines. Mac implements this (`PendingFrameQueue`); Android's responder doesn't read transport frames until after confirmation, so TCP buffers them.

## Multi-hop relay

A device may be trusted-but-not-directly-connected to another device — different LANs, no fallback host configured, or simply not yet discovered — while both have a live connection to some third device. Every device therefore makes a deliver-vs-forward decision on every envelope it receives, using the envelope's own `recipientId`/`broadcast`/`ttl` fields (see `schema/envelope.schema.json`) — a deliberately simple flood-forward with a hop budget and de-duplication, not a shortest-path routing table, since a real Connect mesh is expected to stay small (a handful of devices).

Algorithm, run on every successfully decrypted inbound envelope, before it's handed to the local `MessageRouter`:

```
if envelope.id was already seen (bounded recently-seen cache): drop silently, stop
record envelope.id as seen

isForMe = (envelope.recipientId == myDeviceId) or envelope.broadcast
if isForMe: deliver locally (route to registered handlers)

if envelope.ttl <= 0: stop — no further forwarding, delivered or not

targets =
  if envelope.broadcast: every other directly-connected peer except whichever one this arrived from
  elif recipientId is set and != me:
      if recipientId is directly connected: [that one peer]
      else: every other directly-connected peer except whichever one this arrived from (flood toward it)
  else: none

for each target: send a copy of the envelope with ttl decremented by 1, re-encrypted under that peer's own Noise session
```

A locally-originated send (from a feature manager, not a relay of something just received) goes through the same target-resolution logic with nothing excluded and `ttl` reset to its default (8), and records its own freshly-minted `id` as seen immediately, so a message that somehow finds its way back around the mesh to its own originator is dropped rather than re-delivered.

**Forwarding is never a raw-ciphertext relay.** Each hop's Noise session is pairwise (A↔B and B↔C are independent `NoiseSession`s with independent keys and nonce counters) — a frame arriving encrypted under the sender's session is fully decrypted, then re-encrypted from scratch under the *next* hop's own session before being sent on. There is no way to relay the ciphertext bytes directly.

**De-duplication** guards against both re-delivering the same broadcast twice (if the mesh has more than one path between two devices) and infinite forwarding loops. Each device keeps a small in-memory cache of recently-seen envelope `id`s (bounded to a few hundred entries, oldest evicted first) — this is a size-bounded cache, not a persisted or time-windowed one, since the mesh's expected chat volume (clipboard/DND/media/roster-gossip updates) is low.

This mechanism is also what makes `trust.roster_update`'s broadcast propagate transitively through the whole mesh for free — see that row in `schema/message-types.md`.

## Large binary payloads

Used today by `clipboard.update`'s image variant (see `schema/message-types.md`) — a file-transfer feature used this convention previously, was removed, and any future large-binary feature should reuse the same mechanism:

- The binary bytes are sent as their **own raw frame** (length-prefixed exactly like any other frame, still Noise-encrypted), sent **immediately following** a JSON metadata frame (a normal envelope with `hasRawFollowup: true`) that describes what the binary frame contains (e.g. byte length, content type).
- Binary data must **never** be base64-embedded inside a JSON `payload`. Base64 in JSON costs ~33% size overhead and forces full buffering/parsing of large blobs as text; a raw follow-up frame avoids both.

### Interaction with mesh relay

Because a raw frame carries no addressing of its own, it can't be relayed the way a plain envelope is (a relaying device would try to `Envelope.decode` it as JSON and fail). Instead, `hasRawFollowup` envelopes get a variant of the mesh-relay algorithm above, applied identically on both platforms:

```
if envelope.id was already seen: still arm a "drain and discard" raw-frame handler for the peer
   it arrived from (the raw frame is physically coming next on that connection regardless of
   whether we act on it — dropping the duplicate must not desync the frame boundary), stop

isForMe = (envelope.recipientId == myDeviceId) or envelope.broadcast
targets = (same target-resolution as the plain-envelope algorithm above, using envelope.ttl)

# Unlike a plain envelope, delivery AND forwarding are both deferred — armed as a single
# one-shot handler for the peer this envelope arrived from — until the raw frame itself
# actually arrives:
arm a handler for this peer that, once the raw frame arrives with its bytes:
    if isForMe: deliver the envelope + bytes together to the feature manager
    for each target in targets: forward (envelope with ttl-1) + the same bytes,
        atomically as a pair, re-encrypted under that target's own Noise session
```

The "deliver and forward only once the raw frame arrives, and always as an atomic metadata+raw pair" rule is the key difference from a plain envelope (which delivers/forwards its metadata immediately). Forwarding the metadata alone as soon as it arrived — before the raw frame showed up — would risk some other message (a heartbeat, an unrelated broadcast) getting interleaved on the wire between the forwarded metadata and the (later) forwarded raw frame at the next hop, breaking that hop's "the very next frame is the raw payload" assumption. Sending both together, atomically, under the same per-peer send lock at every hop is what keeps this safe end-to-end across an arbitrary number of relays.

This requires a `send(envelope, rawFollowup)` primitive alongside the normal envelope `send`, and a one-shot raw-frame-handler (`pendingRawFrameHandlers`, keyed by peer) armed by the routing logic above — consumed by the very next frame the receive loop reads from that peer, before it's ever attempted as JSON. See `TransportManager.handleReceivedEnvelope` (Mac) / the receive loop in `launchConnectionLoop` (Android).

### Scope limits (deliberate, for now)

- No chunking: the whole binary payload is one frame. Fine for a clipboard-sized image; a much larger payload (e.g. a real file-transfer feature) would need to reintroduce a chunking scheme (sequence numbers, reassembly) on top of this.
- No integrity check beyond what Noise/TCP already provide (no separate checksum field) — acceptable for the same reason.
