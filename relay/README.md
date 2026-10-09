# gossip-relay

Topic-hub WebSocket relay for Gossip's off-LAN transport (design: [`docs/plans/relay.md`](../docs/plans/relay.md), threat model: [`docs/relay-threat-model.md`](../docs/relay-threat-model.md)).

Every device of a mesh joins one *topic* and holds one WebSocket. Each pair of devices still runs its own Noise session; the relay only routes opaque binary frames by a cleartext 8-byte route tag. It never decrypts, never opens outbound connections, and keeps no state except in-memory topic membership (a restart costs clients a reconnect).

```bash
npm install
npm run dev          # tsx watch, ws://localhost:8080/connect
npm run build && npm start
npm test             # vitest (real in-process ws server + client helper)
npm run gen-vectors  # regenerate ../schema/conformance/relay-vectors.json
```

TLS is terminated in front of this process (Caddy, nginx, a platform LB). Set `RELAY_ORIGIN` to the public `wss://` origin clients use. The hosted relay is `wss://gossip.vmd1.dev`; clients learn the current relay from a small HTTPS directory (a JSON blob with a `relayServer` key, constrained to `vmd1.dev` hosts; see [the plan](../docs/plans/relay.md) "Relay directory"). `RELAY_ORIGIN` must equal the directory's `relayServer` string exactly (`wss://host[:port]`, lowercase, no path or trailing slash), because clients sign it into every join. If the relay moves, change the directory and bring the new relay up with its own `RELAY_ORIGIN`.

## Protocol

Conformance vectors for every derivation below: [`schema/conformance/relay-vectors.json`](../schema/conformance/relay-vectors.json) (also reproduced by `test/vectors.test.ts`). All binary fields in JSON are standard padded base64.

**Crypto**

| Item | Definition |
|---|---|
| `publicKeyHash` | `SHA-256(ed25519 public key, 32 bytes)` |
| `topicId` | `HMAC-SHA256(topicSecret, "gossip-topic" ‖ u64be(epoch))` |
| `topicAuthKey` | `HMAC-SHA256(topicSecret, "gossip-topic-auth" ‖ u64be(epoch))` |
| `verifier` | `SHA-256(topicAuthKey)`; registered by the first joiner, later joiners must match (constant-time compare) |
| `routeTag` | `SHA-256(topicId ‖ publicKeyHash)[0..8]` |
| join `sig` | Ed25519 over `utf8("gossip-relay-join-v1\n") ‖ utf8(relayOrigin) ‖ 0x0A ‖ nonce(32) ‖ topicId(32)` |
| join `proof` | `HMAC-SHA256(key = verifier, msg = nonce)`. Note: the relay stores only `SHA-256(topicAuthKey)`, so it cannot check an HMAC keyed by `topicAuthKey` itself; the join therefore carries `verifier` and the proof is keyed by it |
| PoW | `pow` = 8 bytes (u64be counter) with `SHA-256("gossip-relay-pow-v1" ‖ publicKeyHash ‖ nonce ‖ pow)` having at least `powBits` leading zero bits. Required only if the relay has not seen this `publicKeyHash` before |

**Control messages** (WebSocket text, JSON, at most `MAX_CONTROL_BYTES`):

| Message | Direction | Fields |
|---|---|---|
| `relay.challenge` | S→C on connect | `nonce` (32 B), `powBits` |
| `relay.join` | C→S | `publicKey`(32), `topicId`(32), `sig`(64), `verifier`(32), `proof`(32), `version` ("MAJOR.MINOR"), optional `pow`(8), optional `credential` (string, operator secret) |
| `relay.joined` | S→C | `routeTag` (own), `members` (other members' tags), `limits` |
| `relay.peer_joined` / `relay.peer_left` | S→C | `routeTag` |
| `relay.error` | S→C | `code` |

One join per connection. After any failure except `pow_required` / `pow_invalid` (which allow a retry on the same connection, up to `MAX_JOIN_ATTEMPTS`) the server sends `relay.error` and closes; reconnect for a fresh nonce.

Error codes: `bad_request`, `upgrade_required`, `unauthorized`, `auth_failed`, `pow_required`, `pow_invalid`, `join_failed`, `denied`, `rate_limited`, `limit_exceeded`, `quota_exceeded`, `busy`, `disabled`, `not_joined`, `already_joined`. `join_failed` is deliberately the single answer (same code, same minimum delay) for wrong topic proof, wrong verifier, topic full, route-tag collision, new-topic rate limit and new-topic shedding. A topic that does not exist is simply created, so there is no "no such topic" answer. Treat `join_failed` as "back off and retry".

**Data frames** (WebSocket binary): `dstTag(8) ‖ srcTag(8) ‖ payload`, payload non-empty, total at most `MAX_FRAME_BYTES` (16 MiB + 16). Routed unicast within the sender's topic by `dstTag`; `srcTag` is overwritten with the sender's authenticated tag. Unknown/own `dstTag` is silently dropped (no oracle). Rate-limit and quota drops produce a throttled `relay.error` (`rate_limited` / `quota_exceeded`) to the sender.

Closing a connection by the same key joining the same topic again replaces the old one (old gets close code 4001).

Close codes: 1008 policy (rejected, rate limited, slow consumer, handshake timeout), 1009 too large, 1012 kill switch, 1001 idle.

## Configuration (environment)

All defaults live in `src/config.ts`.

| Variable | Default | Meaning |
|---|---|---|
| `PORT`, `HOST`, `RELAY_PATH` | 8080, 0.0.0.0, `/connect` | listen address and upgrade path |
| `RELAY_ORIGIN` | `ws://localhost:$PORT` | origin bound into join signatures (must equal what clients use) |
| `MAX_FRAME_BYTES` | 16777232 | ws `maxPayload` (16 MiB + 16) |
| `MAX_CONTROL_BYTES` | 2048 | max pre-join / control message size |
| `POW_BITS` | 16 | difficulty for new keys; 0 disables |
| `MIN_CLIENT_VERSION` | 0.0 | version gate on `join.version` |
| `OPERATOR_SECRET`, `ALLOWED_KEYS` | unset | if either set, join needs `credential == secret` or a key hash (hex, comma list) in the allowlist |
| `TOPIC_MAX_MEMBERS` | 16 | topic size cap |
| `MAX_TOPICS_PER_KEY` | 4 | topics one key may be in at once |
| `NEW_KEYS_PER_IP_HOUR`, `NEW_TOPICS_PER_IP_HOUR` | 10, 10 | per IPv4 / IPv6 /64 |
| `CONNECTS_PER_IP_MINUTE`, `MAX_CONNECTIONS_PER_IP` | 60, 20 | connection attempt rate and concurrent cap |
| `MAX_JOIN_ATTEMPTS`, `JOIN_FAIL_DELAY_MS` | 3, 100 | retries for PoW errors; uniform failure delay |
| `TOPIC_LINGER_MS` | 600000 | keep an emptied topic's verifier so it can't be squatted |
| `TOPIC_RATE_BYTES_PER_SEC`, `TOPIC_BURST_BYTES`, `TOPIC_DAILY_QUOTA_BYTES` | 1 MiB, 20 MiB, 2 GiB | per-topic token bucket and UTC-day quota |
| `CONN_RATE_BYTES_PER_SEC`, `CONN_BURST_BYTES` | 1 MiB, 20 MiB | per-connection send bytes |
| `CONN_FRAMES_PER_SEC`, `CONN_FRAME_BURST` | 100, 200 | per-connection frame rate |
| `CONTROL_MSGS_PER_SEC`, `CONTROL_BURST` | 2, 6 | control-message rate (exceeding closes) |
| `MAX_STRIKES` | 200 | dropped frames before a connection is closed |
| `HANDSHAKE_TIMEOUT_MS`, `IDLE_TIMEOUT_MS`, `PING_INTERVAL_MS` | 10000, 3600000, 30000 | handshake deadline, no-message idle cutoff (pongs don't count; 0 disables), ping interval (no pong by the next tick = dead peer) |
| `MAX_SEND_QUEUE_BYTES` | 32 MiB | per-connection outbound buffer; beyond it the slow consumer is disconnected |
| `MAX_CONNECTIONS`, `MAX_TOPICS`, `SHED_RATIO` | 10000, 5000, 0.9 | global caps; at `SHED_RATIO` of either, new topics and new keys are refused first |
| `TRUSTED_PROXY`, `TRUSTED_PROXY_HEADER`, `TRUSTED_PROXY_HOPS` | false, x-forwarded-for, 1 | take the client IP from the Nth-from-last header entry, only when enabled |
| `KILL_SWITCH`, `KILL_SWITCH_FILE` | false, unset | see below |
| `BAN_FILE`, `BAN_RELOAD_MS` | unset, 30000 | ban list file and reload interval |
| `METRICS_PORT`, `METRICS_HOST` | 0 (off), 127.0.0.1 | ops-only listener for `/metrics` |
| `METRICS_PUBLIC`, `METRICS_TOKEN` | false, unset | serve `/metrics` on the public port; optional bearer token |
| `LOG_LEVEL` | info | info, warn, error, silent |

## Operations

- **Health:** `GET /healthz` returns `ok` (or `disabled` when the kill switch is on).
- **Metrics:** Prometheus text at `/metrics` on the ops listener (`METRICS_PORT`). Gauges: `relay_connections`, `relay_topics`, `relay_known_keys`, `relay_bans`, `relay_kill_switch`. Counters: `relay_connections_total`, `relay_joins_total`, `relay_topics_created_total`, `relay_bytes_relayed_total`, `relay_frames_relayed_total`, `relay_frames_dropped_total{reason}`, `relay_rejects_total{reason}`, `relay_quota_hits_total`, `relay_slow_consumers_total`, `relay_handler_exceptions_total`. Alert on each reject reason and on quota/shed spikes.
- **Kill switch:** on = new connections get HTTP 503, joins get `disabled`, and existing connections get `relay.error disabled` + close 1012. Triggers (any is enough): `KILL_SWITCH=1` at start, the existence of `KILL_SWITCH_FILE` (polled every 2 s; `touch` to enable, `rm` to disable), or `kill -USR2 <pid>` to toggle at runtime. Clients treat it like any outage and back off.
- **Ban list:** `BAN_FILE`, one entry per line: `key <hex SHA-256(publicKey)> [expiry ISO-8601]` or `ip <addr> [expiry]` (IPv6 bans the /64). Reloaded every `BAN_RELOAD_MS`; no expiry means permanent.
- **Logging:** JSON lines with event names and coarse reasons only; client IPs are truncated to a /24 (v4) or /48 (v6). No payloads, tags, topic ids or key hashes.
- **Deployment:** behind a TLS proxy with its own connection and rate limits; set `RELAY_ORIGIN`, and `TRUSTED_PROXY=true` only if the proxy overwrites the forwarded header. Docker: `docker build -t gossip-relay . && docker run -p 8080:8080 -e RELAY_ORIGIN=wss://... gossip-relay`, or `docker compose up --build` (read-only filesystem, all capabilities dropped; the image has a `/healthz` healthcheck). Multi-arch (amd64 and arm64) images are built on native runners by `.github/workflows/relay-image.yml` and published to `ghcr.io/<owner>/<repo>/relay` (`latest` from the default branch, branch, `sha-` and version tags).

## Threat model summary

The relay is an untrusted router: Noise end to end with keys pinned at pairing means it can drop or delay traffic and see metadata, but not read, forge or splice. The realistic abuse is bandwidth and resource theft, countered by layered limits (admission: signature, topic proof, PoW, per-IP/​/64 limits, caps; throughput: token buckets and quotas; resources: timeouts, bounded queues, global caps and shedding). Full discussion and residual risks in [`docs/relay-threat-model.md`](../docs/relay-threat-model.md).

## Tests

`test/hub.test.ts` (happy path, auth, uniform errors, PoW, every limit, shedding, slow consumer), `test/ops.test.ts` (kill switch, bans, metrics), `test/limits.test.ts` (units), `test/vectors.test.ts` (conformance vectors), `test/fuzz.test.ts` (random bytes never crash the process).
