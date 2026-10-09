# Relay threat model

Applies to the topic-hub relay in `relay/` ([plan](plans/relay.md), [README](../relay/README.md)). Status: implemented in the server, the Rust core client and the Mac and Android shells.

## Assets and trust

- **Content** of device traffic: protected end to end by pairwise Noise_IK sessions with keys pinned at pairing. The relay never holds keys.
- **Availability** of the relay for legitimate meshes, and the **operator's cost** (bandwidth, CPU, memory).
- **Metadata**: who connects from which IP, topic ids, route tags, timing, volume.

The relay is untrusted for content and trusted only for availability and for not leaking metadata it needn't keep.

## What a malicious or compromised relay can do

| Action | Possible | Why |
|---|---|---|
| Read or modify frames | No | Noise AEAD, pinned peer keys |
| Impersonate a device | No | A forged or misrouted frame fails Noise authentication |
| Replay | No | Noise counters, awaiting-proof check on handshake message 1 |
| Drop, delay, refuse, or disconnect | Yes | Accepted; LAN stays preferred |
| Observe metadata | Yes | IPs, topic ids, tags, timing, volume (minimized in logs) |
| Learn `topicAuthKey`-derived verifier | Yes | It is sent in every join. It only grants the right to join that topic, which a relay can do anyway; it reveals nothing about content keys |
| Open outbound connections / act as a proxy | No | The server only routes between members of one topic |

## Attacker classes and controls

**Unauthenticated network attacker.** Cannot join without a valid Ed25519 signature over a fresh per-connection nonce, domain tag and the relay origin, so a captured join cannot be replayed on another connection or another relay. Handshake timeout, pre-join message size cap (`MAX_CONTROL_BYTES`, enforced inside the WebSocket receiver so it never buffers 16 MiB), control-message rate limit, HTTP header timeouts (slowloris), per-IP/​/64 connection caps and connect rate limit, global connection cap.

**Key and topic minting (Sybil).** Keys are free, so each new public key hash must solve a hashcash puzzle bound to the connection nonce (`POW_BITS`, default 16, about 65k hashes), and new keys and new topics are limited per IPv4 / IPv6 /64 per hour. Topics per key and members per topic are capped. An operator credential or key allowlist can close the relay entirely (private/self-hosted). Further hardening (anonymous credentials, platform attestation) is out of scope for v1.

**Topic prober.** Knowing a `topicId` is not enough: a joiner must present the verifier registered by the first joiner. Wrong proof, wrong verifier, topic full, tag collision, new-topic rate limit and new-topic shedding all produce the same `join_failed` after the same minimum delay, with constant-time comparisons and the same work. No endpoint lists topics or members. Residual leak: an attacker with a valid signature and PoW who joins an arbitrary `topicId` with a random verifier gets `join_failed` if the topic exists and success (a new topic) if not; this is rate-limited by the new-topic and new-key limits, and topic ids are 256-bit HMAC outputs so guessing is infeasible. Observing a real `topicId` (only the relay and members see it over wss) is not enough to join, and emptied topics keep their verifier for `TOPIC_LINGER_MS` so a squatter cannot re-register one while members reconnect.

**Authenticated but abusive member (bandwidth theft).** Per-topic token bucket plus UTC-day byte quota, per-connection byte and frame rate limits, frame size cap, strike-based disconnect. Sustained video-scale traffic is cut off by design (`screen.*` and `control.*` stay LAN-only).

**Slow or dead consumer.** Per-connection outbound queue bound (`MAX_SEND_QUEUE_BYTES`): exceeding it disconnects the receiver rather than buffering. Ping/pong dead-peer cutoff, and an idle cutoff for connections that send nothing.

**Overload.** Global caps on connections and topics. At `SHED_RATIO` the relay refuses new topics and brand-new keys first (`busy` / `join_failed`) so existing meshes keep working; at the hard cap new connections get 503. Kill switch (file, env, or SIGUSR2) disables the relay without a deploy.

**Spoofing inside a topic.** `srcTag` is always overwritten with the authenticated sender's tag; a member cannot address another topic (lookup is per topic); route tags are per-topic so they are unlinkable across topics and epochs.

**Operator-side compromise of logs.** Only event names, counters and coarse reasons are logged, with IPs truncated to /24 (v4) or /48 (v6). No payloads, tags, topic ids or key hashes are logged. Metrics are counters without identifiers and are served only on an ops-only listener (disabled by default on the public port).

**Compromised or malicious relay directory.** Devices learn the current relay from a small HTTPS JSON document (`relayServer`; see [plan](plans/relay.md) "Relay directory"). If that endpoint, its TLS certificate or its DNS is compromised, the attacker can change which relay devices use, but only to a host equal to or under `vmd1.dev` (checked in the core by `parse_directory`, together with `wss://`-only, no userinfo/query/path, lowercase ASCII, no punycode or IP literals); anything else is rejected and the last valid cached answer stays in use. So the directory cannot send devices to an attacker's own domain, and a relay at an allowed host still cannot read, forge or splice traffic. What remains: an attacker who also controls a `vmd1.dev` subdomain (a dangling DNS record, a subdomain takeover) could run a relay there and see metadata (IPs, timing, volume) for devices that follow the directory; keep the `vmd1.dev` zone clean and prefer few, deliberate subdomains. An unreachable or garbage-serving directory is harmless: failed and invalid fetches never replace or clear the cache. Polling sends nothing identifying (no device id, no custom headers), is rate limited (6 h period, 1 to 30 min backoff, one extra poll per 10 min on relay connect failure), and fetches are size and time capped (64 KiB, 10 s). A user's explicit custom relay URL overrides the directory on that device and bypasses the domain rule; it is never read from the directory.

## Cryptographic notes

- Join proof is `HMAC(verifier, nonce)` rather than `HMAC(topicAuthKey, nonce)` because the relay stores only `SHA-256(topicAuthKey)` and could not verify the latter. The verifier is therefore a bearer secret for joining that topic, known to members and the relay; it is protected on the wire by TLS. If a stronger split is wanted later (relay never learning a joinable secret), the join needs a zero-knowledge or signature-based topic credential; that would be a new `relay.join` version.
- The signature domain separates this use of the identity key from envelope signing (`gossip-envelope-v1`) and includes the relay origin, preventing cross-relay replay.
- PoW is bound to the public key hash and per-connection nonce, so solutions cannot be precomputed or shared across connections.

## Residual risks and operations

- A public relay with no accounts cannot be made abuse-proof, only expensive and low-value to abuse. Tune `POW_BITS`, per-IP limits, quotas and the monthly spend cap against load tests.
- IP-based limits are only as good as the trusted-proxy configuration: enable `TRUSTED_PROXY` only behind a proxy that overwrites the forwarded header, otherwise all clients share the proxy's IP (or an attacker spoofs it).
- All state is in memory: a restart resets rate-limit windows, quotas, known keys (new PoW is required again) and verifiers (a topic is re-registered by the next joiner). Acceptable for v1; a restarting attacker-visible window exists for squatting an unclaimed topic, mitigated by topic ids being secret.
- Single instance: no horizontal scaling; per-IP limits are per instance.
- Required before launch (see plan): TLS proxy with its own limits, alerts on every reject reason, spending cap and abuse contact, load tests that exercise each limit including shedding, staged rollout.
