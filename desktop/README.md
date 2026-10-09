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
| `relay_configure(enabled, origin)` | Turn the relay on/off. `origin` is `wss://host` (`ws://` only for local development; a trailing `/connect` is accepted and stripped). It must equal the relay's `RELAY_ORIGIN` exactly: it is signed into every join. Local setting, never gossiped; enforce `wss://` and a host allowlist in release builds yourself. |
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
