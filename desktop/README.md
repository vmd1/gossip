# desktop

The Rust workspace that holds the **sans-IO core** of the Gossip protocol, `gossip-core`, the code that must be
byte-identical on every client. The Mac and Android apps still run their own Swift and Kotlin implementations; the
core is verified against them (and against independently generated vectors) so it can replace them one layer at a
time. See [`docs/plans/desktop-clients.md`](../docs/plans/desktop-clients.md) and
[`docs/plans/relay.md`](../docs/plans/relay.md).

## What is in `core`

| Module | Contents |
|---|---|
| `crypto::noise` | `Noise_IK_25519_ChaChaPoly_SHA256` handshake and transport, as an explicit state machine |
| `crypto::sign` | Ed25519 envelope signing over canonical JSON |
| `crypto::stream` | The directional counter-nonce AEAD for the screen and Universal Control channels |
| `crypto::beacon`, `crypto::pairing` | BLE beacon tags; the pairing comparison code and constant-time token checks |
| `wire` | Length-prefixed framing (stream parser with limits), envelopes, the handshake identity |
| `mesh`, `limits` | De-duplication, deliver-vs-forward, hop budgets; rate limiter, pending-frame queue, "already handled" caches |
| `trust`, `reconcile` | Roster merge and tombstones; on-connect and periodic resend scheduling |
| `engine` | The whole-device state machine: connections, handshakes, pairing, promotion, relaying, heartbeats, relay links and the mesh topic |
| `relay_directory` | The relay directory: `parse_directory` (reads the `relayServer` JSON blob: a `wss://`/`ws://` URL with a host, 16 KiB cap), `merge` (a failed or invalid fetch never replaces a valid cache) and the polling schedule |
| `relay`, `topic` | The relay client (pure functions pinned by `schema/conformance/relay-vectors.json`, and the sans-IO `RelayClient` join/backoff state machine); the `mesh.topic` secret and epoch |
| `features` | Pure feature logic: DND merge, battery alerts, ring, clipboard policy and loop guard, media, notification reply guard, hotspot state, lock-on-leave, the Instant Hotspot GATT protocol, per-feature toggles |
| `control` | Universal Control: frame codec, layout geometry, pointer router |

The core never opens a socket, reads a clock or draws randomness. The shell feeds it bytes and events and executes
the `Action`s it returns; clock and randomness come from the `Env` trait (`TestEnv` makes everything reproducible).
Sockets, mDNS, BLE, storage, OS integration and UI stay in each platform's shell.

## Relay (off-LAN)

The core can join a topic on a relay (`relay/`, [`docs/plans/relay.md`](../docs/plans/relay.md), wire details in
[`docs/wire-protocol.md`](../docs/wire-protocol.md) "Relay transport") and run its normal Noise sessions to trusted peers
through it. The shell only owns one WebSocket:

| Shell calls | Meaning |
|---|---|
| `relay_configure(enabled, origin)` | Turn the relay on/off. `origin` is `wss://host` (`ws://` only for local development; a trailing `/connect` is accepted and stripped). It must equal the relay's `RELAY_ORIGIN` exactly: it is signed into every join. Local setting, never gossiped; enforce `wss://` in release builds yourself. |
| `relay_socket_opened()` | The socket finished opening (after `RelayConnect`). |
| `relay_socket_closed()` | The socket closed or failed on its own. Do **not** report a close the core asked for (`RelayClose`). Detach the old socket's listener when you close it, so a late callback cannot hit the next connection. |
| `relay_text_received(text)` / `relay_binary_received(bytes)` | WebSocket messages. Let the WebSocket library answer pings itself. |
| `tick()` | Drives reconnect backoff, proof-of-work slices, join deadlines, LAN grace and heartbeats. Once a second is plenty. |
| `set_topic(secret, epoch)` | At startup, load what the last `TopicChanged` reported. |
| `is_relayed(device)`, `relay_status()`, `should_dial(device)`, `set_lan_grace_ms(ms)` | UI and policy. `should_dial` stays true for a device that is only reachable over the relay, so keep trying LAN: the first direct link replaces the relayed one without a disconnect event. |

Actions to execute: `RelayConnect{url}` (open a WebSocket to the URL, then report `relay_socket_opened`),
`RelaySendText{text}`, `RelaySendBinary{bytes}` (send as-is, one WebSocket message each), `RelayClose`. Events:
`RelayJoined{members}`, `RelayDown`, `RelayError{code}` (a UI hint: `upgrade_required`, `denied`, `disabled`, ...; the core
backs off itself), and `TopicChanged{secret, epoch}`, which the shell must persist in secure storage (never log it).
Relayed peers appear as ordinary `PeerConnected`/`PeerDisconnected` with virtual connection ids at or above
`VIRTUAL_CONN_BASE` (2^63); keep your own socket ids below that. Nothing happens until the mesh has a topic, which the
first connection between two trusted devices creates and `mesh.topic` distributes.

Policy in the core: a trusted peer is dialed over the relay only after 8 s with no live link (default), only by the side
with the lower `deviceId`, and only if its signing key is known (its route tag derives from it). `screen.*` and
`control.*` are refused on relayed links. A revoke moves the mesh to a new topic the revoked device never receives.

### Relay directory

The relay address can move without an app release: the operator serves an HTTPS JSON blob with a `relayServer` key
(`wss://host[:port]`), and the shells poll it, keep the last good copy and fall back to a built-in default. The core
(`relay_directory.rs`, sans-IO) owns every decision; the shell does HTTP and a file:

| Shell calls (FFI) | Meaning |
|---|---|
| `relay_directory_parse(json)` | The normalized origin for `relay_configure`, or `None`. Rules: JSON object of at most 16 KiB, string `relayServer` that is a `wss://` or `ws://` URL with a host (a trailing `/` is dropped). No host restriction: the directory is trusted to name the relay. Unknown fields are ignored. The origin is signed into every join, so it must equal the relay's `RELAY_ORIGIN`. |
| `relay_directory_decide(cached_json, fetched_json)` | After a fetch (`fetched_json` is `None` when the request failed): `Adopt` (persist the raw body you fetched, apply `relay_server`, `changed` says whether to reconfigure), `KeepCached` (leave the file alone) or `NoDirectory` (use the default). The cached blob is re-validated, so a corrupt cache file is ignored. |
| `RelayDirectoryScheduler` | `should_poll(now_ms, last_success_ms, last_attempt_ms, failures)`: on launch, then every 6 h with +-10% jitter, with 1 min doubling to 30 min backoff after failures; `should_poll_after_connect_failure(now_ms, last_attempt_ms)`: at most one extra poll per 10 min when the relay socket cannot connect; `reroll()` after each attempt. |

Shell rules: HTTPS only, no redirect to another host, 10 s timeout, 64 KiB body cap, no cookies, credentials or
identifiers (a generic `User-Agent` only); poll only while the relay is on; write the raw blob atomically (temp file,
rename) only after it validated. Resolution order on each device: user custom URL (never read
from the directory), cached/polled `relayServer`, built-in default. See [`docs/plans/relay.md`](../docs/plans/relay.md)
"Relay directory" for the threat reasoning.

### Running the live test against a real relay

```sh
cd relay && npm install
PORT=8099 HOST=127.0.0.1 RELAY_ORIGIN=ws://127.0.0.1:8099 POW_BITS=8 npm run dev   # or: npx tsx src/relay.ts
# in another terminal
cd desktop
GOSSIP_RELAY_URL=ws://127.0.0.1:8099 cargo test -p gossip-core --test relay_live -- --ignored --nocapture
```

Two cores that already trust each other join a fresh topic, solve the proof of work, handshake through the relay and
exchange a message. `RELAY_ORIGIN` must match the URL's scheme and host exactly. The test uses `tungstenite` as a
dev-dependency only; the core itself has no WebSocket or networking dependency.

## Bindings (`ffi`)

`gossip-ffi` exposes the core to Swift and Kotlin with [UniFFI](https://mozilla.github.io/uniffi-rs/) (proc-macro
style, no UDL). The core itself has no FFI types; `ffi` only converts. What is bound:

- **`GossipCore`**: the engine (connections, pairing, sending, `tick`, trust snapshot), returning a flat `Action`
  enum the shell executes. An optional `Clock` callback lets the shell (or a test) control time.
- Standalone helpers: identity generation, pairing codes, BLE beacons, the stream cipher, base64.
- The feature objects: `Dnd`, `Battery`, `Ring`, `ClipboardGuard`, `MediaController`, `CommandGuard`, `ReplyGuard`,
  `HotspotStates`, `LockOnLeave`, plus the Instant Hotspot GATT functions.
- Universal Control: frame encode/decode, `ControlLayout`, `PointerRouter`.

Free-form payloads cross the boundary as JSON strings; keys and secrets as byte arrays.

| Script | Produces |
|---|---|
| `scripts/test-swift-bindings.sh` | builds the library, generates Swift, runs a smoke test (two engines pairing, messaging, persistence, features, hotspot, Universal Control) |
| `scripts/test-kotlin-bindings.sh` | the same through the generated Kotlin on a JVM via JNA (Gradle project in `ffi/kotlin`) |
| `scripts/build-xcframework.sh` | `target/swift-package`: a universal macOS XCFramework + generated Swift as a SwiftPM package (`GossipCore`) |
| `scripts/build-android.sh` | `target/android`: `libgossip_ffi.so` for four ABIs + the generated Kotlin (needs the NDK and `cargo-ndk`) |
| `scripts/test-android-library.sh` | loads the arm64 `.so` on a connected device and calls into it through the UniFFI C ABI |

The Android app copies `jniLibs/` into `src/main/jniLibs` and the generated `gossip_ffi.kt` into its sources, and
depends on `net.java.dev.jna:jna:5.17.0@aar`.

## Testing

```sh
cargo test                              # everything portable
./scripts/build-swift-interop.sh        # macOS: builds a harness around the Mac app's real Swift sources
cargo test                              # now also checks interop with that code
./scripts/run-on-android.sh             # runs the core suite on a connected Android device over adb (bionic with the NDK)
```

- `tests/vectors.rs` checks the shared vectors in [`schema/`](../schema): envelope signing, Noise_IK (generated by an
  independent implementation, see `schema/conformance/gen_noise_vectors.py`), the screen and control ciphers, BLE
  beacons.
- `tests/interop_swift.rs` and `tests/hotspot_gatt.rs` drive the Mac app's *actual* `NoiseSession.swift`,
  `Envelope.swift`, `EnvelopeSigning.swift` and `HotspotGattProtocol.swift` in both directions. They skip themselves
  when the harness is not built.
- `tests/relay_engine.rs` runs cores through an in-test relay hub (the server's join and routing rules): handshake and
  messages across the relay, fragmented streams, LAN-first replacement without a flap, screen/control refusal,
  staleness, and `mesh.topic` convergence, idempotency and the revoke bump. `tests/relay_live.rs` is the ignored
  real-relay test above; `src/relay.rs` has the conformance-vector and state-machine unit tests.
- `tests/engine.rs` runs several devices over an in-memory network: pairing, reconnect, relaying, forgery and replay
  rejection, revocation, heartbeats, feature toggles.
- `tests/features.rs` and `tests/control.rs` port the Swift test suites for the logic that moved here.

Toolchain: `rustup` stable (see `rust-toolchain.toml`).
