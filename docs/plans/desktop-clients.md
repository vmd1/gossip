# Plan: Windows and Linux clients, and computer ↔ computer sync

Status: proposal (2026-10-05, resequenced 2026-10-09). Covers the shared Rust core, the Windows and Linux apps, and the "Computer↔Computer" half of Universal Control and Sidecar. The core is now adopted on Mac and Android *first*, then the public relay is added to it ([`relay.md`](relay.md)), then Windows and Linux are built on top.

## Decisions

1. **One shared Rust core (`desktop/core`)** holds everything that must be byte-identical or that has repeatedly drifted between the Swift and Kotlin apps. The core is **sans-IO**: bytes and events in, bytes and actions out. It never opens a socket.
2. **Native UI and OS integration per platform.** Windows: C# + WinUI 3. Linux: GTK4 + libadwaita in Rust (links the core directly, no FFI). No Tauri, no web UI.
3. **The core is adopted on Mac and Android first** (Phase 1), one layer per release, with the old Swift and Kotlin paths kept behind a build flag and run side by side in CI until the vectors and the e2e scripts agree. Mac and Android are the only clients with real traffic and hardware e2e scripts, so they are the right place to prove the core. Windows and Linux come after and inherit a verified core.
4. **Capabilities replace device-type checks.** A device advertises what it can do in the handshake identity payload, instead of peers inferring it from `deviceType`.
5. **Test vectors are the contract.** Every client, including Mac and Android, must pass the shared vectors in `schema/`. The missing Noise vectors are a hard gate before any client work (Phase 0). Because the core must reproduce today's bytes exactly, adopting it on Mac and Android is not itself a wire break.
6. **Off-LAN connectivity is a topic-hub relay implemented in the core** (Phase 2, [`relay.md`](relay.md)). It is built only after the core is verified on Mac and Android, so Windows, Linux and the Chrome extension get it for free.

## Context: what makes this cheaper than it looks

- The mesh already floods broadcasts through every connected device. A Windows PC and a Mac that are each connected to a phone already share `clipboard.update`, `battery.update`, `device.ring`, `dnd.update` and `trust.roster_update` through it. Direct computer ↔ computer links are needed only when no phone is online, or for latency-sensitive features (input sharing, screen streaming).
- Trust gossips transitively (`trust.roster_update` auto-trusts), so once two computers are each paired with a phone, they trust each other without pairing directly.

## What the core owns

| Layer | Contents |
|---|---|
| Crypto | Noise_IK handshake and transport, Ed25519 envelope signing and verification, `ScreenCipher`, control-channel cipher, BLE beacon tag and hotspot GATT crypto |
| Wire | Length-prefixed framing and limits, envelope encode and validate (sanity checks, `rawSha256`), raw follow-up pairing |
| Mesh | Recently-seen id cache, deliver-vs-forward decision, `ttl`, heartbeat timing |
| Trust | Roster merge, tombstones, validation limits, `trust.revoke` handling |
| Reconcile | Scheduling for "on connect and every N seconds" resyncs, so the repo convention lives in one place |
| Pure feature logic | DND merge, battery alerts, ring, clipboard policy and loop guard, media and notification-reply dedupe, hotspot state, lock-on-leave trigger, the Instant Hotspot GATT protocol (chunking, signed payloads, credential encryption, request gate), per-feature toggles and the message types each owns |
| Universal Control | Data-channel frame codec, layout geometry, pointer crossing router |

Not in the core: sockets, mDNS, BLE, reading and writing the clipboard, posting notifications, driving the media player, applying DND, locking the screen, audio, video decode and capture, input injection and capture, the Mac keycode to HID table (each OS has its own source codes), secret storage, UI.

### Binding strategy

- **Linux:** a normal crate dependency.
- **Windows:** two options to spike before committing. (a) UniFFI C# bindings (`uniffi-bindgen-cs`, third-party). (b) A small hand-written C ABI plus P/Invoke. Decision criteria: callback ergonomics, async handling, and build and packaging complexity in the WinUI 3 project.
- **Later:** UniFFI Swift and Kotlin for Mac and Android; `wasm-bindgen` for the Chrome extension.

## Phase 0: protocol generalization and conformance (ships as 2.0)

Adding `windows`/`linux` to the closed `deviceType` enum in handshake identities and roster entries is a wire break for existing peers. Per `CLAUDE.md` this needs a major bump (`VERSION` → `2.0`) and the `schema/` change will be checked by `version-check.yml`. Land all breaking changes together so there is one break.

1. **Noise conformance vectors. Done.** Reading both implementations settled the open question: they are plain, standard `Noise_IK_25519_ChaChaPoly_SHA256` (empty prologue, the IETF ChaCha20-Poly1305 AEAD with a four-zero-byte plus little-endian counter nonce, HMAC-SHA256 HKDF; Mac uses CryptoKit `ChaChaPoly`, Android uses the platform `ChaCha20-Poly1305`, **not** Tink XChaCha). Nothing custom, so the core does not need to change the wire format. The one deviation from the Noise spec is that transport messages may exceed 65,535 bytes (up to 16 MiB, for clipboard images). [`schema/noise-ik-vectors.json`](../../schema/noise-ik-vectors.json) was generated by an independent implementation (`schema/conformance/gen_noise_vectors.py`) rather than by either app; the Rust core passes it and interoperates with the Mac app's actual `NoiseSession.swift` in both roles. The Swift and Kotlin unit tests run the same vectors too (`NoiseSessionTests.testSharedNoiseVectors`, `NoiseSessionTest.shared noise vectors match`; each `NoiseSession` gained an optional ephemeral-key parameter for this, unused in production), so all three implementations are pinned to one independent reference.
2. **`deviceType` additions:** `windows`, `linux`. Unknown types must be skipped, not fatal, in every client from now on.
3. **Capabilities** in the handshake identity payload (e.g. `clipboard`, `notif.receive`, `media.source`, `input.inject`, `input.capture`, `screen.view`, `screen.source`, `battery`, `ring`, `dnd`, `lock`, `hotspot.client`). Being per-connection state, it is reconciled by every reconnect with no extra resync. Replace role checks like "phones only send notifications" with capability checks.
4. **Generalize role-bound messages** in `schema/message-types.md` (same PR as the code, per `CLAUDE.md`):
   - `media.nowplaying`: any device with `media.source` may send it; drop the Android-specific `packageName` assumption (make it an opaque source id).
   - `media.command`: targeted at any source device, not only Android.
   - `display.info`: `displays[]` instead of one size, because computers have several monitors and the Universal Control layout assumes one.
   - `control.*` and `screen.*`: add `backend: "native"` so a computer can be a target or source without scrcpy.
5. **Pairing without a camera.** The armed device shows a short code and advertises over mDNS. The other device lists armed devices, the user enters the code (it derives the `pairingToken`), and the existing 6-digit comparison on both screens confirms. The code only unlocks the attempt; it is not the trust root.
6. **Dial tie-break.** Android is today the listener and Mac the dialer; two computers both listen and dial. Define one rule (lowest `deviceId` dials) and audit `TransportManager` on both platforms for duplicate-connection handling. The relay fallback (Phase 2) reuses the same rule.
7. **Relay vectors.** Pin the relay-layer rules before any client implements them ([`relay.md`](relay.md)): topic id and route-tag derivation, the join signature (with domain tag and relay origin), the topic proof, and the routing header. The relay identity is the Ed25519 public key hash, so no app `deviceId` migration is needed.
8. **Conformance harness.** `schema/conformance/` plus a CI job that runs every client's tests against the vectors (extend `mac.yml` and `android.yml`; new workflows for Windows and Linux).

Exit criteria: Mac and Android on 2.0 pass all vectors, including the relay vectors; no behavior change for users.

## Phase 1: the Rust core, adopted on Mac and Android

- Build `desktop/core`: Noise, framing, envelope, mesh, trust, reconcile scheduler. It passes every vector, and the old Swift and Kotlin implementations pass the same ones.
- Bind it with UniFFI Swift (an XCFramework for Mac) and Kotlin (NDK builds for the Android ABIs). Shells keep their sockets, mDNS, BLE and storage; the core stays sans-IO.
- Adopt one layer per release: crypto and framing, then envelope and mesh dedupe, then trust and reconcile scheduling, then pure feature logic. Stopping after the first two layers captures most of the value.
- Safety net per layer: a build flag falls back to the old path for a release or two; CI runs old and new implementations side by side (differential tests); the existing e2e scripts (`mac/scripts/run-tablet-e2e.sh`, the Android tests) run against both. Mixed meshes (one device on core, one not) must keep working, since the vectors guarantee identical bytes.
- Concurrency contract: the core owns the Noise nonce state, so the shell must call encrypt serially per peer. This replaces today's per-peer `sendQueue` on Mac and its Android counterpart. Document it in the core API.
- Milestone: Mac and Android run the core in production with no user-visible change, and the old paths are deleted.

### Status (2026-10-09)

**Built and verified: `desktop/core` (`gossip-core`), 83 tests, clippy clean.** Everything in the table above except the relay client.

- Verified against the shared vectors in `schema/` (the existing four, plus the new `noise-ik-vectors.json`).
- Verified against the Mac app's *real* `NoiseSession.swift`, `Envelope.swift`, `EnvelopeSigning.swift` and `HotspotGattProtocol.swift` in both directions (`desktop/scripts/build-swift-interop.sh`), including 1 MiB transport messages, byte-identical canonical signing bytes and the hotspot credential encryption.
- Engine tested end to end over an in-memory mesh: pairing with confirmation on both sides, trusted reconnect, relaying across three devices, raw follow-ups, forgery/replay/oversize rejection, revocation, heartbeats, reconciliation timing, feature gating.
- The Swift test suites for the layout, pointer router, ring, battery, DND, media and clipboard guards were ported alongside the code.
- CI: `.github/workflows/core.yml`.

**UniFFI bindings are built** (`desktop/ffi`, crate `gossip-ffi`; see `desktop/README.md`): the engine as `GossipCore` with a flat `Action` enum the shell executes, an injectable `Clock`, the feature state machines, the hotspot GATT protocol and Universal Control, for Swift and Kotlin. They are exercised by smoke tests that drive two engines through the generated bindings (pairing, messaging, persistence and reconnect, features, hotspot, Universal Control): Swift natively (`scripts/test-swift-bindings.sh`) and Kotlin on a JVM through JNA (`scripts/test-kotlin-bindings.sh`). `scripts/build-xcframework.sh` produces a universal macOS XCFramework as a SwiftPM package and `scripts/build-android.sh` produces `libgossip_ffi.so` for four ABIs plus the Kotlin file.

CI (`core.yml`) builds the Swift package and the Android libraries on every core change and uploads them as workflow artifacts; the app workflows (`mac.yml`, `android.yml`, `release.yml`) now build the engine as part of the app build.

### Status (2026-10-09, later): both apps now run on the engine

`TransportManager` on **Mac** and **Android** has been replaced by a thin shell around the Rust engine (`CoreBridge.swift` / `CoreBridge.kt` are the only files that touch the generated bindings). Gone from the apps: the use of the hand-rolled Noise state machine, framing, envelope signing and verification, the mesh forwarding and de-duplication, the handshake trust gating, heartbeats, the rate limiter, the pending-frame queue and the roster/revoke message handling. What stays in the apps: sockets and listeners, discovery (Bonjour/NSD), per-source pending-connection caps, IP address bookkeeping, the pairing UI, the feature managers, and the trust stores' app-only fields. The old `NoiseSession`/`EnvelopeSigning` sources are kept for now as conformance references (their vector tests still run); delete them after a release cycle.

What the migration added to the core: the trust table can be replaced from the shell (`set_trust`), with **provisional** rows that are dialable and verifiable but never announced in roster gossip (Android's scan flow adds one before dialing); the pending-frame queue is bounded by bytes as well as frames (as the Swift one was); `PeerConnected` reports its connection. Mac tests now use throwaway identity and trust stores when hosted by XCTest (previously the test host read the developer's real Keychain items and hung on the access prompt for a freshly built binary).

Verification so far: Mac 182 tests (172 existing + 10 driving two real engines through the bridge), Android 164 tests (8 driving two real engines through JNA, 4 for the trust snapshot), core 87. Hardware results are recorded in the section below once run.

**Still to do:** delete the superseded Swift/Kotlin Noise sources after a soak; move the feature managers onto the core's feature objects (`Dnd`, `Battery`, ...) one at a time; the relay (Phase 2).

**Behavior the core pins down that the apps had left implicit:** the tombstone rule (gossip never revives a revoked device; the `trust.roster_update` row in `schema/message-types.md` described a different rule and was corrected); an initiator rejects an answer from a device other than the one it dialed; consecutive undecryptable frames close a connection.


## Phase 2: public relay in the core

See [`relay.md`](relay.md) for the protocol, the abuse model and the rollout.

- Rewrite the relay server as a topic hub (`relay/`), with the hard limits and operational tooling a public service needs.
- Add the relay client state machine to the core: join and auth, route tags, presence, `mesh.topic`, and the LAN-first fallback policy as core actions the shells execute. **Done (2026-10-09):** `desktop/core/src/relay.rs`, `topic.rs`, engine integration, FFI (`relay_configure`, `relay_*` socket events, `set_topic`, `RelayConnect`/`RelaySend*`/`RelayClose`/`TopicChanged` actions).
- Shell adapters: a WebSocket on Mac and Android, a Settings toggle, and Android foreground-service handling.
- Milestone: two devices on different networks sync clipboard, battery and notifications through a staged relay; then a canary; then public. Windows and Linux inherit it.

## Phase 3: Windows MVP

- Core: already built and proven (Phase 1); add the C# binding. Spike the binding decision first (a day or two), then build on the winner.
- WinUI 3 shell: tray app, device list, pairing (QR display plus code entry), sockets and mDNS in C#, and a WebSocket adapter for the relay.
- Features: clipboard (text and PNG, `AddClipboardFormatListener`), notification receive and inline reply (toast text input), battery, find-my-device, media controller (UI only, no source yet).
- Secret storage: DPAPI for the identity key and trust store.
- Milestone: pair with the real phone and a Mac, and confirm each feature end to end through the mesh. Add a Windows run-e2e script alongside `mac/scripts/run-tablet-e2e.sh`.

## Phase 4: Windows full feature set, then Linux MVP

- Windows: DND, lock-on-leave (BLE advertisement watcher → `LockWorkStation`), Instant Hotspot client (WinRT GATT plus a WLAN profile), screen-mirroring viewer.
- Linux GTK4 shell with the same ladder as Phase 3, then the same Phase 4 additions.

## Phase 5: computers as sources

- Media source: Windows GSMTC, Linux MPRIS.
- Screen share (computer as the streamed device): Windows Graphics Capture plus a Media Foundation H.264 encoder; Linux PipeWire portal plus GStreamer. Reuses the sealed H.264 WebSocket framing from `screen.*` with `backend: "native"`.

## Phase 6: computer ↔ computer Universal Control

1. **Mac ↔ Mac first** on the native backend, so the protocol is pinned on a platform we already control before writing Windows or Linux injectors.
2. Windows injector and capturer, then Linux.
3. The device-side receiver speaks the existing encrypted control frames directly with no scrcpy: `enter`/`leave`/`mouse_move`/`buttons`/`scroll`/`key`/`text`. Pointer position is exactly known with native injection, so the closed-loop `cursor_query` workaround is not needed.
4. Open questions: the session setup (`control.session_start` with a WebSocket port) versus a multiplexed direct stream; keyboard-layout handling for `key` and `text`; clipboard hand-over on edge crossing.

## Portability of the current Mac features

Mac feature → Windows / Linux, with the main obstacle.

| Feature | Windows | Linux | Notes |
|---|---|---|---|
| Pairing and trust | Yes | Yes | Needs the camera-less flow (Phase 0). Identity key goes in DPAPI / Secret Service instead of Keychain. |
| Clipboard | Yes | X11 yes; **Wayland hard** | GNOME Wayland blocks background clipboard reads (same wall as Android). KDE and wlroots offer `wlr-data-control`. GNOME needs a Shell extension. |
| Notification mirroring and reply | Yes | Partly | Windows toast text input works. Linux inline reply depends on the notification server; fall back to a small reply window. |
| Media controller | Yes | Yes | UI only. |
| DND sync | **Risky** | Yes | Windows Focus Assist has no public API (undocumented WNF); same risk tier as Mac's private lock call. Linux: GNOME `show-banners`, KDE via D-Bus. |
| Lock on leave | Yes | Yes | The BLE beacon logic lives in the core. Lock: `LockWorkStation` / `loginctl lock-session`. Verify BLE range-loss behavior on real adapters. |
| Instant Hotspot (client) | Yes | Yes | WinRT GATT plus a WLAN profile; BlueZ plus NetworkManager. Needs real-hardware verification, as on Mac. |
| Find my device (ring) | Yes | Yes | Override volume via `IAudioEndpointVolume` / `wpctl`. |
| Battery sync | Yes | Yes | `GetSystemPowerStatus` / UPower. |
| Screen mirroring viewer | Yes | Yes | H.264 hardware decode via Media Foundation / GStreamer VA; raw PCM audio is trivial. The scrcpy control encoding is platform-neutral. |
| Universal Control (source) | Feasible, **hard** | X11 feasible; **Wayland unsure** | Windows: low-level hooks, cursor hide and clamp, HID usage mapping. Linux Wayland needs the InputCapture portal; support varies by compositor and version. `PointerRouter` and `ControlLayout` move into the core; `ControlEventTap` and `SystemCursorController` are the Mac-specific parts to rewrite. |
| Device Mirroring launcher | Yes | Yes | Mac installs a launcher app that opens `connect://mirror`; equivalent: a Start-menu shortcut plus a URL handler, or a `.desktop` file. |
| Single-instance guard, onboarding permissions, menu-bar UI | Rewrite | Rewrite | Platform UI; no logic to reuse. |

Summary: everything is portable in principle. The real risks are on the OS side: **Linux Wayland** (clipboard and input capture), **Windows DND** (undocumented), and **Universal Control as a source** on both. Protocol, trust, mesh and reconcile logic carry over wholesale through the core.

## Risks

- **Noise interop.** Resolved: the construction is standard Noise and the core interoperates with the Mac app's real code (see Phase 0 step 1). Android is covered by the shared vectors, not yet by running its Kotlin code.
- **Regressing the working Mac and Android apps.** Adopting the core touches the transport every feature depends on. Mitigations are in Phase 1: vectors first, one layer per release, the old path behind a flag, side-by-side CI, and mixed-version meshes.
- **A public relay's abuse and cost surface.** Handled by the layered limits, proof of work and spending breaker in [`relay.md`](relay.md); it cannot be made abuse-proof without accounts, only expensive and low-value to abuse.
- **Bindings on two more targets.** UniFFI Swift and Kotlin add an XCFramework and a multi-ABI NDK build to CI and release.
- **Core bindings quality** on C# (spike first).
- **Linux fragmentation.** Target GNOME and KDE on Wayland first, X11 as a fallback; tray icons on GNOME need an extension.
- **Distribution.** Windows needs code signing for SmartScreen plus a winget or MSIX path. Linux needs Flatpak, AppImage and deb (the Flatpak sandbox constrains BLE and input). `release.yml` should attach these to the `VERSION` release (see `docs/building-and-signing.md`).
- **Contributor cost.** Rust and C# on top of Swift and Kotlin.

## Documentation to update when work starts

`ROADMAP.md` (build order, the Windows/Linux rows and the off-LAN row), `docs/architecture.md` (it still says the relay is deferred), `docs/wire-protocol.md` (relay transport), `schema/message-types.md` (including `mesh.topic`), `docs/building-and-signing.md` (core build steps), and ADR 0003 (Implementation section: add the Rust core).
