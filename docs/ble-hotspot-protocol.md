# Instant Hotspot — BLE control channel

Companion to `docs/ble-proximity-protocol.md`. Feature 3 from the BLE proximity/lock-on-leave/
hotspot handoff. **Status: the full manual-toggle feature — privileged call, GATT channel, signed
+ encrypted request/response, credential read, and a first-cut UI — is built and live-verified
end to end on real hardware** (this Mac + Samsung SM-S711B, Android 16): a real
Mac-originated request over BLE GATT turned the phone's hotspot on, read back its real SSID and
password via a Shizuku-brokered privileged call, encrypted them, and the Mac decrypted and
recovered them correctly. See "Status as of this session" below for the full breakdown and the
live-test transcript. Not yet built: `hotspot.auto_config`/the WAN-reachability probe (auto-
hotspot-on-timeout), UI polish, and live-testing a couple of symmetric paths this session's
hardware couldn't reach (Android-as-requester, Mac's own auto-connect actually joining a
network) — see "Not yet built" at the end of this doc.

## Design decisions made

- **Scope**: both the manual toggle and the auto-hotspot-on-timeout trigger, built together
  (not staged).
- **"Offline" for auto-hotspot-on-timeout**: real internet/WAN reachability, not just mesh-peer
  liveness — needs a small periodic connectivity probe distinct from the existing
  `connectionState`/heartbeat machinery, which only tracks whether a mesh peer is reachable, not
  whether *this device* has a working internet path. Not yet implemented.
- **GATT request authentication**: sign with the sender's existing Ed25519 identity key
  (`IdentityKeyStore.signingKey`), verified by the recipient against the sender's already-known
  Ed25519 public key — authenticity only, no confidentiality, since "turn hotspot on/off" and its
  status aren't secrets. **Not yet implemented, and blocking**: `TrustedDevice`/pairing/roster-
  gossip currently only carry the X25519 *key-agreement* public key (for Noise_IK), never the
  Ed25519 *signing* public key — there is nowhere today for a receiver to look up a peer's Ed25519
  public key to verify a signature against. This needs a real schema extension (a new field on
  `TrustedDevice` on both platforms, propagated through pairing and `trust.roster_update`) before
  any signed-GATT-request code can be written at all. Do this first.
- **GATT roles — resolved, updated from the original Mac/tablet-only assumption**: a
  hotspot-*providing* phone is always the GATT server (peripheral); the GATT *client* (central) role
  is generic over requester device type — Mac, an Android tablet, **or another Android phone** — not
  hardcoded to Mac/tablet as originally written here. This matches the actual requirement: any device
  with no internet connectivity should be able to request Instant Hotspot from any nearby opted-in
  phone. See `docs/ble-proximity-protocol.md`'s "Roles" section for how a phone plays both its normal
  peripheral role and, on demand, a client role to request from another phone
  (`BLEProximityMonitor.startHotspotRequestScan`) — resolved as an on-demand secondary scan rather
  than a permanent second role, since a phone requesting hotspot is a deliberate, occasional user
  action, not a continuous background behavior like the primary advertise/scan roles. A central (of
  any device type) only opens an actual GATT *connection* to a phone it has already confirmed
  nearby — via the existing `BLEProximityMonitor.nearbyDeviceIds` primitive for Mac/tablet, or via a
  `startHotspotRequestScan` result for a requesting phone — and, per the opt-in gate below, only to a
  phone currently advertising the hotspot-available capability bit.
- **Opt-in gate — "Provide Instant Hotspot" toggle**: a phone offers itself as a hotspot source only
  when `OnboardingPreferences.provideHotspotEnabled` is on (off by default — flips on cellular data
  and battery use for a phone that might not volunteer). Implemented: a persistent row on
  `ConnectHomeScreen` (phone-only, `MainActivity.kt`/`ConnectHomeScreen`), gating both the BLE
  advertisement's capability bit (`BLEProximityMonitor.setHotspotAvailable`, see
  `docs/ble-proximity-protocol.md`) and — once the GATT server below exists — its willingness to
  accept a `hotspot.toggle_request` at all. A phone with the toggle off doesn't advertise the
  capability, not just refuse requests after the fact.

## Resolved blocker — Android 16's `TETHER_PRIVILEGED` lockdown

The handoff's original assumed mechanism — grant `android.permission.WRITE_SECURE_SETTINGS` via
`adb shell pm grant`, then call `ConnectivityManager`/`TetheringManager.startTethering` via
reflection (exactly SimpleWear's open-source `TetherHelper.kt` approach) — **was implemented and
tested live, and confirmed insufficient on Android 16** (Samsung SM-S711B, API 36):

- Both the entitlement-exempt attempt and the SimpleWear-style retry without the exemption fail
  with error 14 (`TETHER_ERROR_NO_CHANGE_TETHERING_PERMISSION`).
- Even `adb shell cmd wifi start-softap` itself is denied: `SecurityException: Uid 2000 does not
  have access`. Android 16 requires the signature-only `TETHER_PRIVILEGED` permission, which
  nothing short of Shizuku or root grants a normal app.
- **Android 10–15 evidence is genuinely mixed, not confirmed either way** — some reports show
  `TETHER_PRIVILEGED` enforced even on much older Android on certain OEM builds, others show
  plain `CHANGE_WIFI_STATE`/`WRITE_SECURE_SETTINGS` sufficing. `TetherHelper.kt` doesn't bet on
  either claim: it tries the plain path first on <16 (cheap, no onboarding), and falls back to
  Shizuku if that fails and Shizuku happens to be set up.

**The actual working mechanism** (confirmed via a real, currently-maintained reference app,
`github.com/supershadoe/delta`, and mirrored independently by SimpleWear's own `wearsettings`
companion module): Shizuku gives the app a shell-UID Binder handle; calling the **raw hidden**
`ITetheringConnector` AIDL interface directly (not the public `TetheringManager` wrapper, which
ties the call to the app's own real identity and is exactly what gets rejected) with the caller
package spoofed as `"com.android.shell"` satisfies whatever check rejects a normal app's own
identity. Implemented in `TetherHelper.kt`/`ShizukuManager.kt`; the hidden-API stub classes
(`ITetheringConnector`, `TetheringManagerHidden`, etc. — vendored from Delta's own
`system-api-stubs` module) live in their own Gradle module,
`android/system-api-stubs/`, `compileOnly`-referenced from `app` — this split is **required**,
not just cleaner: the `dev.rikka.tools.refine` plugin's bytecode-rewriting trick (which lets
`TetheringManagerHidden`'s calls resolve to the real hidden `android.net.TetheringManager` at
runtime) produces class files whose declared "nest host" is the real framework class; if those
compiled stub classes are part of the same module actually being dexed into the APK (as they
were on a first attempt), D8 fails with `requires its nest host TetheringManager to be on
program or class path` — `compileOnly`-ing a separate module keeps the stub classes out of the
app's own dex output entirely, which is what makes the trick work.

**Shizuku itself was the actual remaining blocker, not the tethering call** — now resolved:

- Shizuku's official `v13.6.0` release (the one the original handoff downloaded and installed)
  has a real upstream regression on Android 16: its server crashes on startup with
  `UnsatisfiedLinkError: dlopen failed: library "...librish.so" not found` — Android 16's
  stricter linker namespace isolation blocks loading a native lib directly from inside the APK
  zip (confirmed via `RikkaApps/Shizuku#1174`).
- Downgrading to `v13.5.4` (the last version before the regression) hits a *different* crash:
  `AbstractMethodError` on `IProcessObserver.onProcessStarted` — that framework callback
  interface's signature changed in Android 16 (API 36), and `v13.5.4` predates the fix for it.
  Neither official release works on this exact device/OS combination.
- A third-party fork, `github.com/GentleClash/Shizuku` (tag `shizuku-fix`,
  `v13.6.0.r1094.4ae64007`), patches exactly the `librish.so` issue — its starter copies native
  libraries to a temp path before starting the server, sidestepping the namespace restriction,
  while otherwise being the `v13.6.0` build (so it already has the `IProcessObserver` fix too).
  Installing it required manual intervention (downloading a third-party APK was blocked by an
  automated safety classifier for the session that found it, even with explicit user
  authorization — the user downloaded and installed it themselves).
- **Activation, for the record** (this fork's "Start via ADB" flow differs from stock Shizuku —
  no `start.sh`/external-storage extraction step; instead it directly executes the extracted
  native lib as a binary): `adb shell <path-to-installed-apk-dir>/lib/arm64/libshizuku.so` (the
  exact path is shown in Shizuku's own "View command" dialog under "Start by connecting to a
  computer" — it's per-install, copy it from there rather than assuming a fixed path). Needs
  repeating after every device reboot, same as stock Shizuku.
- **Confirmed live** (Samsung SM-S711B, Android 16): `shizuku_server` starts and stays up under
  shell UID with no crash; Connect's `ShizukuManager` reports `CONNECTED` (binder alive +
  permission already granted, no manual permission-dialog tap needed in this instance — matched
  the `Shizuku.checkSelfPermission()` check on first read, cause not fully investigated); `adb
  shell am broadcast -a com.connect.DEBUG_TOGGLE_HOTSPOT --ez enable true` →
  `setHotspotEnabled(true) -> SUCCESS`, `adb shell ip addr show swlan0` showed a real assigned
  IP; `--ez enable false` → `SUCCESS` and the interface came back down cleanly. (`dumpsys wifi |
  grep SoftApManagers` was observed unreliable earlier this project's history — `ip addr show
  swlan0` is the reliable ground truth.)

`TetherHelper.setHotspotEnabled` returns a clean `ToggleResult` (`SUCCESS`/`FAILURE`/
`PERMISSION_DENIED`/`SHIZUKU_NOT_READY`) rather than crashing in the failure cases too, so the
rest of the feature's plumbing (GATT channel, signed-request auth, UI) can be built without this
being a live risk.

**Done (was a TODO here)**: `TetherHelper` no longer picks a mechanism from `Build.VERSION.SDK_INT`
alone. It was refactored (see `HANDOFF_ONBOARDING_AND_POLISH.md` Phase 1) into an ordered
`MECHANISMS: List<HotspotToggleMechanism>` (`WriteSecureSettingsMechanism`,
`ShizukuHotspotMechanism` — `android/app/src/main/kotlin/com/connect/features/hotspot/
HotspotToggleMechanism.kt`), tried in order by `setHotspotEnabled` unless a
`preferredMechanismId` is supplied. Onboarding's "test hotspot methods" step (Phase 2 —
`OnboardingActivity.kt`'s `HotspotTestStep`) calls the new `TetherHelper.probeMechanisms()` once,
persists the winning mechanism's `id` via `OnboardingPreferences.preferredHotspotMechanismId` (a
local, per-device preference — never sent over the wire), and `SyncForegroundService`'s hotspot
call site reads it back so runtime doesn't have to re-probe or guess from SDK level. **Caveat**:
the probe step only calls `isAvailable()` (a permission/connection check), not an actual
`trySetEnabled()` toggle — so it can't catch a device-specific mechanism that reports available
but still fails to actually toggle in practice; see that handoff phase's "Known gaps" for the
open UX question (a real toggle-and-revert would be more thorough but also more disruptive/
visible during onboarding). Also still open: this whole path is build-verified only, not yet
live-tested on a real device (no onboarding run has happened outside a compiler yet).

## Status as of this session — the GATT channel, credential exchange, and auto-connect are built and live-verified end to end (Mac↔phone)

Everything from "Not yet built" in the previous version of this doc is now implemented. Summary,
newest/most-load-bearing first:

- **`TrustedDevice` Ed25519-public-key schema extension**: `signingPublicKey` travels in
  `handshake.hello`/`handshake.ack` (both directions, every pairing and every reconnect handshake)
  and in the pairing QR payload (`responderSigningPublicKey`). Persisted as
  `TrustedDevice.signingPublicKey` (Android, nullable `ByteArray`) / `.signingPublicKeyBase64`
  (Mac, nullable `String`); a row paired before this field existed gets backfilled via
  `trust.roster_update` gossip (see that row in `schema/message-types.md`) rather than needing a
  re-pair. **Live-verified**: real Mac↔phone handshakes this session actually carried and consumed
  this field (see the "Live end-to-end test" section below).
- **Multi-device requester role flexibility**: a phone can run an on-demand secondary BLE scan
  (`BLEProximityMonitor.startHotspotRequestScan`/`.stopHotspotRequestScan`, Android) to request
  hotspot from another phone, without needing its own always-on scanning role. Mac/tablet need no
  equivalent change — their existing continuous scan already answers "who's nearby and offering
  hotspot." See `docs/ble-proximity-protocol.md`'s "Roles" section. Build-verified; not yet
  exercised with a real second phone as requester (only Mac-as-requester was live-tested this
  session, per the user's own scoping — Android-tablet-as-requester and phone-as-requester are
  architecturally identical to what *was* tested, just untried with different hardware).
- **"Provide Instant Hotspot" opt-in toggle**: a persistent row on `ConnectHomeScreen` (Android,
  phone-only), off by default, persisted via `OnboardingPreferences.provideHotspotEnabled`. Gates
  both the advertisement's capability bit and the GATT server's willingness to act on a request.
  **Live-verified**: toggling it off correctly produced `hotspot.status{ok: false}` from a real
  request; toggling it on correctly allowed the toggle to proceed.
- **BLE advertisement capability bit**: advertisement byte 10 (Android) / byte 12 (Mac, which
  includes the 2-byte company ID CoreBluetooth doesn't strip) signals "hotspot available" without
  needing a GATT connection to check. See `docs/ble-proximity-protocol.md`.
- **The GATT service itself**: custom service (`HotspotGattProtocol.SERVICE_UUID`,
  `8f9a1000-1a2b-4c3d-9e0f-1234567890ab`) with a write characteristic (request) and a notify
  characteristic (response), chunked at a fixed conservative 19-byte payload per chunk (1 flag byte
  + 19 = 20, fits the *default* un-negotiated 23-byte ATT MTU everywhere — this channel never
  depends on MTU negotiation succeeding, trading a few extra round-trips for chunking that just
  always works regardless of stack/OEM behavior). Android peripheral: `HotspotGattServer.kt`.
  Android/Mac central: `HotspotGattClient.kt`/`.swift`. **Live-verified end to end** — see below.
- **`hotspot.toggle_request`/`hotspot.status` payload framing**: compact JSON (`HotspotGattProtocol.kt`/
  `.swift`, kept in sync as this feature's own source of truth for this channel, same as
  `schema/message-types.md` is for the mesh transport — this is a GATT payload, not an `Envelope`,
  so it isn't in that file per this doc's original design note). Every request/response is signed
  with the sender's Ed25519 key and verified against the peer's `TrustedDevice.signingPublicKey`.
  **Also encrypted, not just signed** (a deliberate strengthening over the original design intent
  of "authenticity only, no confidentiality" — a Wi-Fi passphrase is more sensitive than a toggle
  boolean, and a plaintext-but-signed credential exchange would still leak the passphrase to any
  nearby BLE eavesdropper even though they couldn't forge or tamper with it): the `hotspot.status`
  response's `ssid`/`pass` fields are AES-256-GCM-encrypted under a key derived via X25519 ECDH
  between the two devices' *existing* identity keys (`TrustedDevice.publicKey`, the same key
  Noise_IK already uses) with SHA-256 + a domain-separation label
  (`HotspotGattProtocol.deriveSharedSecretKey`) — no new key material, and the label keeps this
  derivation from ever colliding with the Noise_IK session key the same keypair also produces.
- **Credential read** (`HotspotCredentialReader.kt`, Android providing side): `WifiManager.
  getSoftApConfiguration()` and `SoftApConfiguration` are `@SystemApi` — not in the public SDK stub
  jar at all (a direct typed call fails to *compile*, confirmed). A direct reflective call from the
  app's own UID fails live with `SecurityException: App not allowed to read or update stored WiFi
  Ap config` (confirmed via full stack trace on real hardware). **The Shizuku path works**,
  confirmed live: unlike the hotspot *toggle* (which has to spoof the caller package as
  `"com.android.shell"` on a parameter `ITetheringConnector` takes), `IWifiManager.
  getSoftApConfiguration()` takes **no parameters at all** — the permission check is purely against
  the Binder transaction's calling UID, and a `ShizukuBinderWrapper`-wrapped call runs with
  Shizuku's shell UID as that calling identity, which already holds `NETWORK_SETTINGS`. No vendored
  AIDL stub needed (unlike `ITetheringConnector`) — `IWifiManager` is a real on-device class, just
  not a public one, so `IWifiManager.Stub.asInterface(...)`/`getSoftApConfiguration()` are called
  via plain reflection. This resolves what the previous version of this doc flagged as "the actual
  remaining unknown... bigger than the already-solved toggle problem."
- **Credential auto-connect**: `HotspotAutoConnect.kt` (Android, `WifiNetworkSpecifier`, API 29+,
  no special permission — a one-time immediate connection request, not a persistent suggestion) and
  `HotspotAutoConnect.swift` (Mac, `CWInterface.associate`, gated behind Location Services
  authorization — a macOS-wide requirement for any app joining Wi-Fi programmatically, unrelated to
  what this app actually uses location for; see `NSLocationWhenInUseUsageDescription` in
  `Info.plist`). **Android path untested this session** (no second device available to actually
  join a hotspot as a *requester* and verify the join); **Mac path build-verified only, not
  live-tested** — calling `associate` would have disconnected this Mac's own Wi-Fi mid-session,
  which would have disrupted the very development environment this feature was being built in, so
  that specific test was deliberately deferred rather than skipped through lack of effort. Both
  paths are otherwise wired into the "Request Hotspot" UI (below) and ready to exercise once
  there's a safe opportunity.
- **UI, first cut**: a "Request Hotspot" button next to a nearby, hotspot-advertising phone's row
  — `PairedDevicesScreen.kt`/`MainActivity.requestHotspot` (Android, feedback via `Toast`) and
  `MenuBarView.swift`'s `hotspotButton`/`requestHotspot` (Mac, feedback via a caption line under the
  device row). Functional, not polished — no persistent progress UI, no retry affordance. This is
  the feature's actual manual-trigger surface; the temporary `connect://debug-hotspot-request` URL
  hook and Android's `DEBUG_SET_PROVIDE_HOTSPOT` broadcast receiver used to live-test this session
  should be removed once this UI itself has been exercised directly (not just via the debug hooks).

### Live end-to-end test (this session, real hardware: this Mac + Samsung SM-S711B)

With the phone's "Provide Instant Hotspot" toggle on and Shizuku connected, a Mac-originated
request (via the temporary debug URL hook) produced, over real BLE GATT, no Wi-Fi/mesh transport
involved at any point:

```
debug-hotspot-request: requesting from 1b5d6ad5-ea91-403f-ad2b-853b3cd9eadb
debug-hotspot-request result: success(enabled: true, ssid: Optional("Vivaan"), passphrase: Optional("Vivaan123"))
```

`adb shell ip addr show swlan0` on the phone confirmed a real assigned IP at the same time — the
toggle genuinely turned the hotspot on, not just reported success. With the toggle off, a repeat
request correctly came back `success(enabled: false, ssid: nil, passphrase: nil)` (the signature
still verified; the server just declined to act, per the opt-in gate).

**One real bug found and fixed during this test**: `HotspotGattClient.swift` created a fresh
`CBCentralManager` per request and checked `.state == .poweredOn` *synchronously* right after
`init` — but a freshly-created manager starts in `.unknown` and only reports `.poweredOn`
asynchronously via `centralManagerDidUpdateState`, so essentially every request failed immediately
with "Bluetooth is not powered on" even though Bluetooth was genuinely on. Fixed by deferring the
connect attempt to that callback when the manager isn't powered on yet at request time.

**A second, more serious bug found live** (not during the GATT test itself — during ordinary
manual toggling afterward): `TetherHelper.setHotspotEnabled(enable = false)` reported `SUCCESS`
**twice in a row** while the phone's hotspot stayed fully live the whole time — same
`SoftApManager` instance (`dumpsys wifi`'s `mAmmToReadyForChangeMap`), same assigned IP,
unchanged across both "successful" stop calls and several seconds of waiting. Root cause,
found by comparing directly against `github.com/supershadoe/delta`'s `SoftApController.
stopSoftAp`/`startSoftAp` (the real, currently-maintained reference this whole privileged-call
mechanism is based on): `ITetheringConnector` here is a **compile-time-only stub** — `dev.rikka.
tools.refine`'s bytecode rewriting swaps every call against it for the real on-device
`android.net.ITetheringConnector` class at runtime. If a specific overload declared in our
vendored stub doesn't exist on *this exact device's* real platform class, calling it throws
`NoSuchMethodException` at the call site — which is exactly why Delta's own `stopSoftAp`/
`startSoftAp` try several call shapes in fallback order rather than assuming one fixed signature.
Two concrete fixes, both ported from Delta's verified-working approach:
- `ShizukuHotspotMechanism.startTetheringWithFallback`/`.stopTetheringWithFallback`
  (`HotspotToggleMechanism.kt`) now try each `startTethering`/`stopTethering` overload our
  vendored `ITetheringConnector` stub declares, falling through on `NoSuchMethodException`,
  **passing `null` (not `""`) for the calling-attribution-tag parameter** — the previous `""`
  is the most likely single cause of the silent no-op stop: an empty-string attribution tag may
  not resolve the same way `null` (Delta's actual value) does in the framework's attribution-
  source/permission-check machinery, plausibly explaining a stop that returns a clean
  `TETHER_ERROR_NO_ERROR` without actually tearing the AP down.
- `TetherHelper.setHotspotEnabled` no longer trusts a mechanism's own success report at all: it
  now polls the real `WIFI_AP_STATE` (`TetherHelper.verifyState`, ~2s bounded) after every
  reported success and only returns `ToggleResult.SUCCESS` once the real state actually confirms
  it — a mechanism that can't be verified is treated as failed and the next mechanism in the
  ordered list gets a real attempt, rather than the caller trusting a callback that (confirmed
  live, twice) can lie.

**Live-reverified after the fix**: toggled hotspot on (fresh `SoftApManager` id), then off —
`swlan0` genuinely went to `state DOWN` with its IP gone, and `dumpsys wifi` showed no
`SoftApManager` at all afterward (previously: same manager instance, unchanged, across two
"successful" stops). As a bonus, the new verification step also caught a live false-positive
from `WriteSecureSettingsMechanism` in the same test run ("reported success but real hotspot
state didn't confirm it") and correctly fell through to `ShizukuHotspotMechanism`, which then
genuinely worked — direct evidence the verification step is pulling its weight, not just
theoretical defense in depth.

**Also encountered, not a code bug**: two rounds of stale-process confusion during testing — once
where the *Mac* app process was stale relative to a rebuilt binary (the same class of bug
`hotspot_write_secure_settings_insufficient.md`-adjacent memory doesn't cover, but the exact
pattern the "Mac launch + Bluetooth TCC crash" memory's sibling issue warns about: always verify a
running process's start time against the binary's build time before trusting a "why isn't this
working" investigation), and once where the *phone* app had two `SyncForegroundService` process
instances registering competing `BluetoothGattServer`s simultaneously (likely `adb install -r`
racing an existing `START_STICKY` service restart across this session's many rapid reinstalls) —
resolved with `adb shell am force-stop com.connect` before relaunching. Neither was a real protocol
bug, but both produced confusing failures (`"Field 'signingPublicKey' is required... missing"` and
`"Malformed hotspot.toggle_request"` respectively) worth recognizing quickly in a future session
rather than re-diagnosing from scratch.

### Second live-testing round — UI icon, GATT reliability, auto-connect, and cross-reconciliation

A further round of hands-on testing (the user actively clicking the real "Request Hotspot" UI, not
just the debug hook) found five more real bugs, all fixed and live-reverified:

1. **GATT response chunks silently dropped, causing a spurious timeout.** Both `HotspotGattClient
   .swift` and `.kt` called `setNotifyValue`/`writeDescriptor` to subscribe to the response
   characteristic, then immediately started writing the request chunks — without waiting for
   confirmation the subscription had actually taken effect
   (`peripheral(_:didUpdateNotificationStateFor:)` / `onDescriptorWrite`). When the phone responded
   fast, its notifications arrived before the subscribe had gone through and were silently dropped —
   the toggle genuinely happened server-side, but the client waited the full 15s timeout having
   received nothing, then reported `"Failed: timed out waiting for a response"` even though the
   action had visibly occurred. Fixed on both platforms by deferring the request write until the
   subscription-confirmed callback fires. **Live-reverified**: response now arrives in ~2s instead
   of timing out.
2. **Server reported the wrong resulting state for a successful *stop*.** `HotspotGattServer.kt`
   computed the correct `enabled` value (`result == SUCCESS && request.en`, i.e. "the *resulting*
   state, not just whether the operation succeeded") but then didn't pass it to `sendResponse` —
   that call independently re-derived `enabled = result == SUCCESS`, which is `true` for *any*
   successful operation regardless of direction. A successful stop therefore reported
   `enabled: true`, and the requester's UI said "that device kept its hotspot on" immediately after
   it had genuinely just been turned off. Fixed by reusing the already-correct `enabled` local
   instead of recomputing it inline.
3. **Icon never visually changed state.** `MenuBarView.swift`'s hotspot icon applied
   `.foregroundStyle` *inside* the `Button`'s `label` closure — on macOS, a `Button`'s own
   `.borderless` style tinting overrides a style applied only to its label content, so the icon
   never visually reflected a state change even though the underlying `@Published` data updated
   correctly (confirmed via debug log). Fixed by moving `.foregroundStyle` onto the `Button` itself.
   Separately, the color also needs to be an explicit `.blue`, not `Color.accentColor` — the system
   accent color can itself be set to gray/graphite in System Settings, which would make "on" and
   "off" visually indistinguishable regardless of the first fix.
4. **Auto-connect (`HotspotAutoConnect.swift`) hung indefinitely, then failed silently, before
   finally working.** Three compounding issues, found and fixed in sequence via live testing:
   - `requestAlwaysAuthorization()` was called while only `NSLocationWhenInUseUsageDescription` (not
     the `Always` variant) was declared in `Info.plist` — the mismatch meant no system prompt ever
     appeared, no delegate callback fired, and the request hung forever with nothing to show for it.
     A 15s timeout was added as a general safety net regardless of root cause.
   - Switching to `requestWhenInUseAuthorization()` (matching the existing Info.plist key, and
     genuinely sufficient — this only ever needs one-time authorization for a single scan+associate,
     not continuous background location access) *still* showed no prompt.
   - Root cause: the app is sandboxed (`com.apple.security.app-sandbox`), and a sandboxed macOS app
     needs the explicit `com.apple.security.personal-information.location` entitlement for Location
     Services to work at all — the Info.plist usage-description string alone is necessary but not
     sufficient once sandboxed. Adding the entitlement (`Connect.entitlements`) was the actual fix;
     confirmed embedded via `codesign -d --entitlements -` before retesting.
   - **Live-verified working end to end** after all three fixes: a real request auto-connected this
     Mac to the phone's hotspot.
5. **The on/off indicator itself had no self-healing path** (a design gap, not a code bug, but found
   the same way): `hotspot.state_update`'s mesh broadcast was the *only* source for the icon, so a
   Mac that lost its mesh connection to the phone kept showing a stale belief indefinitely — no
   periodic resync could reach it, because the resync itself travels over the same down connection.
   Concretely: hotspot on (Mac's icon correctly showed on) → Mac's mesh connection drops → phone
   turns hotspot off independently → Mac's icon still shows on, stale, forever. Pressing the button
   against that stale belief then sent the wrong request. Fixed by adding a second BLE advertisement
   capability bit (bit 1, alongside the existing "willing to provide" bit 0) carrying live on/off
   state — see `docs/ble-proximity-protocol.md`'s advertisement payload section and
   `BLEProximityMonitor.setHotspotOn`/`.isHotspotOn`. This is a genuinely different resilience
   property than the mesh signal: BLE never depended on a Wi-Fi/mesh connection existing at all, so
   it can't go stale the same way. The UI on both platforms now merges the two sources, preferring
   the BLE bit's `enabled` value whenever the peer is currently BLE-nearby (fresher by construction)
   while keeping the mesh report's `ssid` either way.

## Not yet built

- `hotspot.auto_config` — purely local per-pair configuration (a timeout duration), never sent
  over the wire, similar to `TrustedDevice.fallbackHost` today. Needed for the WAN-probe-triggered
  auto-hotspot below, not for the manual toggle (which has no timeout concept).
- The WAN-reachability probe (auto-hotspot-on-offline-timeout) — lowest priority per this feature's
  original handoff; the manual toggle above is "the more immediately useful half of this feature"
  and has no dependency on this existing first.
- Polished UI beyond the first cut above: a persistent in-progress indicator, retry affordance, and
  a UX decision on whether a received credential auto-connects silently or shows a "Connecting to
  <phone>'s hotspot..." transition state.
- Removing the temporary debug hooks (`connect://debug-hotspot-request` in `ConnectApp.swift`,
  `DEBUG_SET_PROVIDE_HOTSPOT`/`DEBUG_READ_HOTSPOT_CREDENTIALS` broadcast receivers in
  `SyncForegroundService.kt`) once the real UI has been exercised directly in place of them.
- Live-testing the requester-side paths not covered above: Android tablet or phone as requester
  (architecturally identical to the tested Mac-as-requester path, but untried). Mac's
  `HotspotAutoConnect.swift` *is* now live-verified (see the second live-testing round above) —
  Android's `HotspotAutoConnect.kt`/`WifiNetworkSpecifier` equivalent is still build-only.
