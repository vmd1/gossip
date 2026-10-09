# Plan: public relay (off-LAN connectivity)

Status: relay server and core client implemented (2026-10-09); Mac shell adapter done (`URLSessionWebSocketTask`, Settings toggle, `mac/scripts/e2e-relay.sh`); Android OkHttp adapter, hosted relay host choice, rollout pending. Originally a proposal. Implements the roadmap's "Off-LAN connectivity" item. Sequenced after the Rust core has been adopted on Mac and Android (see [`desktop-clients.md`](desktop-clients.md), Phases 1 and 2). Replaces the earlier idea of a pairwise byte-bridging relay and the tailcat signaling mailbox as the first off-LAN transport.

## Decisions

1. **Topic hub, pairwise crypto.** Every device in a mesh joins one *topic* on the relay and holds a single WebSocket. Each pair of devices still runs its own Noise_IK session, carried inside frames the relay routes by a cleartext tag. No group key, so trust, `trust.revoke` and the existing Noise code are unchanged.
2. **The relay is a dumb, untrusted router.** It never decrypts, never makes outbound connections, and cannot reach anything except other members of the same topic. A compromised or malicious relay can drop or delay traffic and see metadata; it cannot read, forge or splice traffic, because Noise keys are pinned from pairing.
3. **Implemented in the Rust core, after the core is verified.** The relay *client* is a sans-IO state machine in `desktop/core`; shells only run a WebSocket. The relay *server* stays TypeScript in `relay/`.
4. **A public relay we host.** There are no user accounts, so abuse resistance comes from layered limits and cost control, not identity. Self-hosting is supported with the same server.
5. **LAN first.** The relay is a fallback. Bulk and latency-sensitive features (`screen.*`, `control.*`) refuse relayed paths.

## Protocol sketch

Details are pinned by test vectors in `schema/conformance/` (Phase 0) before any client implements them.

**Relay-layer identity is the Ed25519 public key**, not the app's UUID `deviceId`. The relay-visible id is `SHA-256(publicKey)`. This binds the id to the signing key without changing app-level `deviceId`s, so no pairing or roster migration is needed.

**Topic keys.** A mesh has a `topicSecret` and an `epoch`. From these:

- `topicId = HMAC(topicSecret, "gossip-topic" || epoch)`, the public rendezvous name.
- `topicAuthKey = HMAC(topicSecret, "gossip-topic-auth" || epoch)`, used for a join proof.
- `routeTag = SHA-256(topicId || publicKeyHash)[0..8]`, a per-topic short address, so tags are unlinkable across topics.

**Control messages (JSON, WebSocket text frames):**

| Message | Direction | Purpose |
|---|---|---|
| `relay.challenge {nonce}` | server → client | Fresh random nonce, per connection |
| `relay.join {publicKey, topicId, sig, proof, version}` | client → server | `sig` = Ed25519 over `domainTag ‖ relayOrigin ‖ nonce ‖ topicId`; `proof` = HMAC(topicAuthKey, nonce). The first joiner registers `H(topicAuthKey)` as the topic verifier; later joiners must match it |
| `relay.joined {members: [routeTag…], limits}` | server → client | Current members and the limits that apply |
| `relay.peer_joined` / `relay.peer_left {routeTag}` | server → client | Presence, which drives the dial policy |
| `relay.error {code}` | server → client | Uniform codes; no distinction that leaks whether a topic exists |

**Data frames (WebSocket binary):** `dstTag(8) ‖ srcTag(8) ‖ payload`. The payload is the same `[len][Noise ciphertext]` stream the LAN transport uses, so the core's stream parser must not assume one WebSocket message equals one frame. The relay routes by `dstTag` (unicast only) and overwrites `srcTag` with the authenticated sender's tag so it can't be spoofed.

**`mesh.topic` (wire message, applied by the core):** carries `topicSecret` and `epoch`. Persistent state on the recipient, so it follows the reconcile convention: sent on every fresh connect plus a periodic resync. Highest `epoch` wins, with a deterministic tie-break, so applying a duplicate is a no-op (idempotent). A `trust.revoke` bumps the epoch and the new secret is withheld from the revoked device. Documented in `schema/message-types.md` in the same change that ships it.

**Bootstrap and migration.** The first device that upgrades generates a `topicSecret` and gossips it over its existing Noise links. Devices without the secret simply have no relay path yet.

## Abuse and security model

### What the relay can and cannot do

| Concern | Outcome |
|---|---|
| Read or modify traffic | No. Noise end to end, keys pinned at pairing |
| Impersonate a device | No. A frame misdelivered or forged fails Noise authentication |
| Replay | No. Noise counters; the existing "awaiting proof" check covers replayed handshake message 1 |
| Drop, delay, or refuse to route | Yes. Accepted; LAN stays preferred |
| Observe metadata | Yes: IPs, topic ids, route tags, timing, volume. Minimized, see below |
| Be used as an open proxy or reflector | No. It never opens outbound connections and only routes between members of one topic |

The realistic abuse is therefore **bandwidth and resource theft**: someone using the relay as a private pipe between their own devices, or exhausting it with many connections, topics or slow readers.

### Controls (all limits are starting values to tune against load tests)

**Admission**
- Authenticated join only: Ed25519 signature over a server nonce, with a domain tag and the relay origin so a signature can't be replayed on another relay or topic.
- Topic proof: knowing a `topicId` alone is not enough to join. The relay is also the one party that sees `topicId`, so the proof stops anyone who merely observes or logs it.
- Proof of work on first contact: a new public key must solve a small hashcash challenge before its first join. Negligible for a real device, which pays it once, costly for an attacker minting thousands of keys.
- Per-IP (and per-/64 for IPv6) limits on new keys and new topics per hour.
- Topic size cap (initially 16 members), and a cap on topics per key.
- Optional operator credential (allowlist of keys or a shared secret) for private and self-hosted relays.
- A later hardening step, not v1: anonymous issuance (Privacy Pass style) or platform attestation (App Attest, Play Integrity) to gate new-key registration.

**Throughput (makes it useless as a general tunnel)**
- Maximum frame size equal to the apps' frame limit; the WebSocket server's `maxPayload` set to match.
- Token bucket per topic: a modest sustained rate with a burst allowance sized for a clipboard PNG, plus a daily byte quota per topic.
- Per-connection send rate limit, a control-message rate limit, and a bound on connect and join attempts.
- Sustained video-scale traffic is cut off by design; `screen.*` and `control.*` stay LAN-only.

**Resource exhaustion**
- Handshake and idle timeouts; ping/pong with a dead-peer cutoff; slowloris protection.
- Bounded per-connection send queues; a slow consumer is disconnected, never buffered without limit.
- Global caps on connections, topics and memory. At the cap the relay sheds *new* topics and joins first so existing meshes keep working (a circuit breaker with a spending budget).
- Per-IP connection caps. The client IP comes from a trusted proxy header only when the proxy is configured as such.

**Probing and enumeration**
- Uniform error responses and timing for "no such topic", "bad proof" and "topic full".
- No endpoint lists topics or members; presence is only visible to someone who has already authenticated into the topic.

**Metadata and transport**
- `wss://` only in release builds; clients ship an allowlist of relay hosts. The relay URL is a local setting and is never gossiped or remotely settable.
- Log counters and coarse reasons, not payloads, tags or full IPs beyond a short retention window; documented in the privacy notes.
- Route tags are per-topic and `epoch` rotation changes topic ids, so passive tracking across epochs is not possible.

**Client behavior**
- Reconnect with exponential backoff and jitter, so a relay restart doesn't cause a thundering herd.
- Existing inbound rate limiting, envelope validation and trust checks apply unchanged to relayed peers.
- The relay is used only after LAN and BLE discovery fail for a few seconds, and dropped once a LAN path appears.
- A version field in `relay.join` lets the relay reject clients below a minimum version, and a kill switch lets us disable the relay without shipping a build.

### Operations (required before launch)

- Behind a TLS-terminating proxy with its own connection and rate limits; health endpoint; structured metrics for connections, topics, bytes, rejects and quota hits; alerts on each.
- Ban list by key and IP, with expiry, and a documented abuse contact.
- A monthly budget cap and an alert at partial spend.
- Fuzzing for the control-message parser and frame handling; load tests that exercise every limit, including the shedding behavior; a documented threat model in `docs/`.
- Deployed behind a staged rollout: staging, then an allowlisted canary, then public.

## Implementation notes (2026-10-09)

Where the implementation refines the sketch above (the conformance vectors in `schema/conformance/relay-vectors.json` are authoritative):

- `relay.join` carries a `verifier` = `SHA-256(topicAuthKey)` and `proof = HMAC-SHA256(key = verifier, msg = nonce)`, because the relay stores only the verifier and cannot check an HMAC keyed by `topicAuthKey`. `relay.challenge` carries `powBits`; `relay.joined` carries the device's own `routeTag`. `pow_required`/`pow_invalid` leave the socket open for a retry.
- The client is `desktop/core/src/relay.rs` (`RelayClient`, sans-IO) wired into `Core` (`engine.rs`): relayed peers are virtual connections (ids at or above `VIRTUAL_CONN_BASE`) running the same Noise_IK code as TCP links. Dial policy, grace (8 s), the lower-`deviceId`-initiates tie-break and the screen/control refusal are core logic. `mesh.topic` is `desktop/core/src/topic.rs` plus the engine, reconciled every 5 minutes inside the core (it never surfaces as `ReconcileDue`).
- Route tags for trusted peers are derived from their signing keys, so a peer whose signing key is not yet known is skipped.
- A relayed link needs no shell socket: the core returns `RelayConnect`, `RelaySendText`, `RelaySendBinary` and `RelayClose`, and `relay_*` input methods for socket events.
- Verified against a real relay in `desktop/core/tests/relay_live.rs` (ignored by default; see `desktop/README.md`).

## Work breakdown

1. **Relay server rewrite (`relay/`).** Topic hub, join proof, unicast routing, presence, every limit above, tests. The old `relay.connect` bridge logic and its `pendingRequests` map are removed. Metrics and ops tooling.
2. **Core relay client (`desktop/core`).** Join/auth state machine, route-tag handling, presence events, `mesh.topic` handling, and the LAN-first fallback and dial tie-break as core actions (`DialLan`, `JoinRelay`, `SendRelayFrame`). Conformance vectors for topic derivation, the join signature and proof, and the routing header.
3. **Shell adapters.** WebSocket glue on Mac (`URLSessionWebSocketTask`) and Android (OkHttp); a "Relay" toggle and an optional custom relay URL in Settings; Android foreground-service handling for the held socket and its battery cost.
4. **Rollout.** Staging relay, dogfood on real devices, canary, public launch. Windows and Linux inherit it from the core.
5. **Docs.** `docs/architecture.md` (currently says the relay is deferred), `docs/wire-protocol.md` (relay transport), `schema/message-types.md` (`mesh.topic`), the relay README, and the threat model.

## Resolved decisions (2026-10-09)

- **Operator.** The project owner (vmd1) runs the hosted relay. Start with a single small instance behind a TLS-terminating proxy; the relay is stateless apart from in-memory topic membership, so a restart only costs clients a reconnect. Before launch, pick the host, set a hard monthly spending cap with a partial-spend alert, and publish an abuse contact address. Sizing is an estimate to validate with the load tests, not a promise.
- **Topic secret bootstrap.** The first device that upgrades generates a random 32-byte `topicSecret` at `epoch = 1` and gossips it in `mesh.topic` over its existing Noise links. Devices that already hold one ignore a lower epoch.
- **Conflicting secrets.** Highest `epoch` wins; on an equal epoch the larger `SHA-256(topicSecret)` wins. Every device applies the same rule, so they converge without flapping, and re-applying the same message is a no-op.
- **Concurrent revocations.** If two devices revoke different peers at the same time, each bumps to the same new epoch with a different secret, and the tie-break may pick the secret that was shared with a device the other side revoked. Revocations are monotonic tombstones, so the rule is: after adopting a topic, a device that knows of a revoked peer who received it bumps to `epoch + 1` with a fresh secret and redistributes it to non-revoked peers only. This converges because the set of revoked devices only grows.
- **`mesh.topic` and the 2.0 bump.** Define `mesh.topic` in the 2.0 schema together with the other breaking changes, even though the relay ships later, so launching the relay needs no further major bump. Per `CLAUDE.md` the `schema/message-types.md` row is added in the change that makes the type real.
- **Defaults.** Topic size cap 16 members; 8-byte route tags (collisions are negligible at that size); one topic per mesh for v1.

## Risks and open questions

- **Public relay with no accounts can't be made abuse-proof**, only expensive and low-value to abuse. The rate limits, PoW and budget breaker are what keep cost bounded. If abuse appears despite them, escalate to anonymous credentials or attestation.
- **Android battery** cost of a held socket; consider only holding it while the LAN path is down.
- **Limit values** (token bucket, daily quota, PoW difficulty, per-IP caps) need tuning against load tests and real usage before launch.
- **Host choice and budget** for the hosted relay, and the abuse contact address.
