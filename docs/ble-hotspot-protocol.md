# Instant Hotspot — BLE control channel (in progress)

Companion to `docs/ble-proximity-protocol.md`. Feature 3 from the BLE proximity/lock-on-leave/
hotspot handoff. **Status: the privileged-call mechanism is fully live-verified end-to-end on
Android 16** — `TetherHelper.kt`/`ShizukuManager.kt` implement both the Android 10–15
(`WRITE_SECURE_SETTINGS`) and Android 16+ (Shizuku/raw-AIDL) paths; the Android-16 path was
confirmed on real hardware (Samsung SM-S711B) via the temporary `com.connect.
DEBUG_TOGGLE_HOTSPOT` broadcast receiver: `setHotspotEnabled(true)` returned `SUCCESS` and a
real `swlan0` interface came up with a real assigned IP, and `setHotspotEnabled(false)` brought
it back down cleanly. See "Resolved blocker" below for the full mechanism and the Shizuku
version saga that had to be worked through first. The GATT channel, signed-request auth, and UI
below are still unbuilt — that's the actual remaining work now, not the privileged call.

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
- **GATT roles**: unstated explicitly but implied by symmetry with `docs/ble-proximity-protocol.md`
  — phones are BLE peripheral (GATT server), Mac/tablets are BLE central (GATT client), matching
  the existing proximity-scan role split. A central only opens an actual GATT *connection* (not
  just passive scanning) to a phone it has already confirmed nearby via the existing
  `BLEProximityMonitor` primitive.

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

**TODO (onboarding)**: `TetherHelper` currently picks a mechanism from `Build.VERSION.SDK_INT`
alone, given the mixed Android-10–15 evidence above. Once there's a real onboarding flow for this
feature, it should *probe* which mechanism actually works on the user's specific device/OS build
(try the cheap path, fall back and remember the result) rather than assuming from SDK level.

## Not yet built

- The `TrustedDevice` Ed25519-public-key schema extension above.
- The BLE GATT service itself (custom write + notify characteristics), on both the Android
  peripheral (GATT server) and Mac/tablet central (GATT client) sides.
- `hotspot.toggle_request`/`hotspot.status` payload framing over that GATT channel (small,
  purpose-built — not an `Envelope`/`schema/envelope.schema.json`-shaped message, since this
  travels over BLE GATT directly, not the Wi-Fi mesh transport; see the design point in this
  feature's original handoff about why the mesh transport can't be assumed reachable here).
- `hotspot.auto_config` — purely local per-pair configuration (a timeout duration), never sent
  over the wire, similar to `TrustedDevice.fallbackHost` today.
- The WAN-reachability probe.
- Manual toggle UI (Mac + tablet) and the auto-hotspot-on-timeout settings UI.
