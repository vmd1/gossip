# Handoff: Connect — Instant Hotspot via Shizuku, Android clipboard fix, tablet Lock-on-Leave verification

Repo: `/Users/vivaan/Projects/coding/connect`, GitHub `vmd1/connect`, branch `main`. This is a live continuation
of a long session that built and live-verified BLE proximity (Feature 1) and Lock-on-Leave (Feature 2, both
platforms), then got deep into Instant Hotspot (Feature 3) and hit — then broke through — a real Android 16
platform wall. Read this whole document before writing code; it is intentionally exhaustive because you have
no memory of the session that produced it.

## Devices / environment

- Mac: build via `xcodegen generate` (after adding/removing Swift files) then `xcodebuild -project
  Connect.xcodeproj -scheme Connect -configuration Debug build`. **Launch via `open
  .../Build/Products/Debug/Connect.app`, never the raw binary path** — launching the raw Mach-O directly
  crashes on first CoreBluetooth use with a misleading TCC error even when Info.plist is correct; `open`
  (proper LaunchServices registration) fixes it. Kill via `pkill -f "Connect.app/Contents/MacOS/Connect"`.
- Android phone: Samsung SM-S711B, **Android 16 / API 36**, serial `R5CWB1SSLMJ` (USB) — this is the phone
  that pairs as `android-phone` and is the one Instant Hotspot's hotspot-toggle code runs on. It has a real
  PIN lock configured (confirmed via `dumpsys lock_settings`).
- Android tablet: Samsung SM-T500, Android 12 / API 31, reachable at `192.168.0.169:45999` (wireless adb;
  drops intermittently — `adb connect 192.168.0.169:45999` to reconnect, this is normal/expected per project
  practical notes, not a bug). Pairs as `android-tablet`.
- Both devices: `adb install -r <apk>` + `adb shell am force-stop com.connect` + `adb shell am start -n
  com.connect/.ui.MainActivity` to deploy and relaunch after every change. No Gradle daemon issues observed.
- **Auto-mode classifier note**: at least one `xcodebuild` invocation was blocked by an automated "Security
  Weaken" classifier after an entitlements-file diff, requiring the user to run the build command themselves
  in their own terminal. If you hit this, don't fight it — hand the exact command to the user and wait.

## Session memory files already saved (read these first — do not re-derive)

In `/Users/vivaan/.claude/projects/-Users-vivaan-Projects-coding-connect/memory/`, indexed in `MEMORY.md`:
- `mac_launch_bluetooth_tcc.md` — the `open` vs. raw-binary launch issue above, in more detail.
- `lock_on_leave_cooldown.md` — the user's requirement that lock-on-leave must not repeatedly re-lock while
  a device stays out of range (edge-trigger + cooldown, already implemented on both platforms).
- `hotspot_write_secure_settings_insufficient.md` — the now-superseded finding that `WRITE_SECURE_SETTINGS`
  alone doesn't work on Android 16. **Superseded by the Shizuku/Delta finding in this document** — the memory
  file should be updated (not deleted — keep the history) to note the real working mechanism once you've
  implemented it, since a future session will otherwise re-tread the same dead end.

## What's fully done and live-verified this session (don't redo)

1. **Feature 4 (UI reorg)**: icons instead of text device-type subtitles, home-row actions vs. "…" settings
   submenu, on both platforms. Done, tested live, working.
2. **Feature 1 (`BLEProximityMonitor`)**: phones advertise (BLE peripheral), Mac/tablets scan (BLE central).
   Protocol documented in `docs/ble-proximity-protocol.md` — **read it**, it has the exact manufacturer-data
   wire format, thresholds (6s loss timeout, -75dBm RSSI floor, 2-hit confirm), and two real bugs found and
   fixed live (a `Timer.scheduledTimer`-vs-`.common`-run-loop-mode bug that paused staleness detection while
   the Mac's menu was open, and an RSSI-gating bug where a weak-but-present signal never counted as "left").
3. **Feature 2 (Lock-on-Leave), Mac side**: `mac/Connect/Features/Proximity/LockOnLeaveManager.swift`. Locks
   via the private `SACLockScreenImmediate` (dlopen/dlsym from `login.framework`) — **not** AppleScript/System
   Events, which was tried first and blocked by Accessibility TCC never registering the app at all (this
   project's ad-hoc code signature churns every rebuild, and TCC state got confused; `tccutil reset
   Accessibility com.connect.app.Connect` was needed once, then the private-API approach was built instead of
   continuing to fight Accessibility TCC). **Confirmed live**: real range-loss detected, real screen lock
   fired, cooldown correctly suppressed a second spurious trigger.
4. **Feature 2, Android (tablet) side**: `android/app/src/main/kotlin/com/connect/features/proximity/
   LockOnLeaveManager.kt`, using `DevicePolicyManager.lockNow()` gated on device-admin (`res/xml/
   device_admin.xml`, `ConnectDeviceAdminReceiver.kt`, onboarding button in `MainActivity.kt`/`ui/
   PairedDevicesScreen.kt`'s "Lock this device when I leave" toggle — only shown when *this* device is a
   phone and the *target* row isn't a phone, since only phones are BLE-detectable). Device admin was already
   granted on the tablet via `adb shell dpm set-active-admin com.connect/.features.proximity.
   ConnectDeviceAdminReceiver` (still active — verify with `adb shell dpm list-owners` or similar before
   assuming). **Compiles and installs cleanly but the actual live "walk the phone out of range, does the
   tablet lock" test was never run** — the user said "we'll test the feature on the tablet at the end." Do
   that test as your first action if nothing else has invalidated the setup.
5. `schema/message-types.md` has the `lock_on_leave.config` row fully documented (direction, payload, and a
   long note on both platforms' actual lock mechanisms) — this is up to date, no action needed there for
   Lock-on-Leave.

## Instant Hotspot — where it stood before the breakthrough, and what changed

`docs/ble-hotspot-protocol.md` has the design decisions made this session (manual toggle + auto-timeout both
in scope; WAN-reachability probe, not just mesh-peer-liveness, defines "offline"; Ed25519-signed GATT
requests for auth). **That file's "Open blocker" section is now stale/wrong and must be rewritten** — it
documents the `WRITE_SECURE_SETTINGS`-insufficient finding as if it were a dead end; it wasn't, see below.

### The actual working mechanism (confirmed via a real, currently-maintained reference app — not guessed)

Android 16 requires the signature-only `TETHER_PRIVILEGED` permission for `TetheringManager.startTethering`
— confirmed exhaustively this session: `WRITE_SECURE_SETTINGS`, `WRITE_SETTINGS`
(`Settings.System.canWrite`), and `CHANGE_WIFI_STATE` were all correctly granted (verified via `adb shell
dumpsys package com.connect` / `appops get`) and it still failed with `TETHER_ERROR_NO_CHANGE_TETHERING_
PERMISSION` (code 14) on both the entitlement-exempt attempt and the SimpleWear-style retry without the
exemption. Even `adb shell cmd wifi start-softap` (uid 2000, shell) is denied with a `SecurityException`.
This is real and confirmed by independent sources: [Marco Gomiero's writeup](
https://www.marcogomiero.com/posts/2025/spoton-sunset/) and a [GrapheneOS tracker issue](
https://github.com/GrapheneOS/os-issue-tracker/issues/6133) both hit the identical wall on Android 16.

An `AccessibilityService` tapping the real Settings/Quick-Settings hotspot toggle was tried and **does
work** (confirmed live: real `swlan0` interface came up with a real IP after a programmatic tap) — but only
when the phone is unlocked; the user explicitly ruled this out as "too janky" and wanted something that
works with the phone locked, fully programmatically, not OEM-UI-specific.

**The real answer**: a currently-maintained, real open-source app called **Delta**
(`github.com/supershadoe/delta`, package `dev.shadoe.delta`) does exactly this — "can be used to turn
hotspot on or off in Android 16 without root" (confirmed via web research and by cloning and reading its
actual source, at `/tmp/delta-ref` on this machine as of this session — re-clone if that's gone:
`git clone --depth 1 https://github.com/supershadoe/delta.git`).

**How it works, precisely** (all verified by reading the real source, not summarized secondhand):

1. It uses **Shizuku** (`github.com/RikkaApps/Shizuku`) purely to obtain a Binder handle running with
   **shell UID (2000)** privilege — not for a Shizuku-specific permission, just shell-level Binder access.
   Shizuku itself needs no root; it's activated via `adb shell sh <path-to-its-start-script>` once per boot
   (or can be kept alive via Shizuku's own "start on boot" if the phone is rooted, but ADB activation is the
   relevant path for this project — not root).
2. It does **not** call the public `TetheringManager.startTethering()` Java wrapper (which is what this
   project's `TetherHelper.kt` currently does, and which ties the call to the actual calling app's real
   identity/UID — always `com.connect`, a normal unprivileged app, hence the code-14 denial). Instead it
   gets the **raw hidden AIDL Binder interface** for the "tethering" system service directly:
   ```kotlin
   // dev.shadoe.delta.data.modules.SystemServicesModule
   private fun getSystemService(name: String): IBinder =
     SystemServiceHelper.getSystemService(name)?.let { ShizukuBinderWrapper(it) }
       ?: throw BinderAcquisitionException("Unable to get service: $name")

   fun provideTetheringManager(): ITetheringConnector =
     ITetheringConnector.Stub.asInterface(getSystemService("tethering"))
   fun provideWifiManager(): IWifiManager =
     IWifiManager.Stub.asInterface(getSystemService("wifi"))
   ```
   `SystemServiceHelper.getSystemService` and `ShizukuBinderWrapper` are from Shizuku's own API library
   (`dev.rikka.shizuku:api`) — `SystemServiceHelper` does `ServiceManager.getService(name)` and
   `ShizukuBinderWrapper` wraps the resulting `IBinder` so every `transact()` call on it is routed through
   Shizuku's privileged (shell-UID) server process instead of running as the calling app's own UID.
3. It then calls `startTethering`/`stopTethering` **directly on that raw AIDL interface**, passing
   `"com.android.shell"` as the caller-package-name argument (`ADB_PACKAGE_NAME` constant in
   `dev.shadoe.delta.data.softap.internal.Utils`):
   ```kotlin
   // dev.shadoe.delta.data.softap.SoftApController — the exact call, several fallback overload
   // shapes tried in order since the AIDL method signature has changed across Android versions:
   val request = TetheringManagerHidden.TetheringRequest.Builder(TETHERING_WIFI).build()
   tetheringConnector.startTethering(request.parcel, "com.android.shell", null, dummyIntResultReceiver)
   ```
   This is the crux of why it works where this project's `TetherHelper.kt` didn't: running as shell UID
   *and* asserting the caller package is `com.android.shell` together satisfy whatever the tethering
   service's permission/trust check actually is — which is evidently more lenient than the public
   `TetheringManager` wrapper's own caller-identity check (which uses the real app's `Context.
   getOpPackageName()`/attribution, always `com.connect`, always denied). The earlier `cmd wifi
   start-softap` shell-UID test that seemed to also fail is a **different, unrelated code path** (a
   hardcoded UID==2000 check inside `WifiShellCommand`'s own debug-command dispatcher, not the real
   `ITetheringConnector`/`ConnectivityService` permission logic) — that test's failure did not, in
   retrospect, prove what it was assumed to prove. Don't re-litigate this; it's settled by reading Delta's
   actual working source and (once you implement it) by a live test.
4. `ITetheringConnector`/`IWifiManager` are `@hide` framework interfaces not in the public SDK. Delta
   vendors **compile-time stub classes** for them (bodies just `throw new RuntimeException("stub!")`) built
   against `dev.rikka.tools.refine` (the Refine hidden-API-bypass toolchain — the same one SimpleWear's
   `hidden-api` module uses, already researched this session) which rewrites calls against these stubs to
   the real hidden classes at build time. The files are small and self-contained:
   - `/tmp/delta-ref/system-api-stubs/src/main/java/android/net/ITetheringConnector.java` (79 lines)
   - `/tmp/delta-ref/system-api-stubs/src/main/java/android/net/wifi/IWifiManager.java` (79 lines)
   - Supporting `.aidl` parcelables under `/tmp/delta-ref/system-api-stubs/src/main/aidl/android/net/`:
     `IIntResultListener.aidl`, `TetherStatesParcel.aidl`, `TetheredClient.aidl`,
     `TetheringConfigurationParcel.aidl`, `TetheringInterface.aidl`, `TetheringRequestParcel.aidl`, and
     under `android/net/wifi/`: `SoftApState.aidl`.
   - Also look at `TetheringManagerHidden` (used for `TetheringRequest.Builder`) and `SoftApConfigurationHidden`
     — these come from the `hidden-api`-style Refine bridge classes; check
     `/tmp/delta-ref/api/src/main/kotlin/dev/shadoe/delta/api/` and however Refine's own published hidden-api
     bridge artifacts are declared in `/tmp/delta-ref/gradle/libs.versions.toml` (`refine = "..."`,
     `shizuku = "13.1.5"`) — copy the same dependency coordinates (`dev.rikka.shizuku:api`,
     `dev.rikka.shizuku:provider`, `dev.rikka.tools.refine:runtime`/`:annotation`/`:annotation-processor`).
   - `SoftApController.kt` (`/tmp/delta-ref/data/src/main/kotlin/dev/shadoe/delta/data/softap/
     SoftApController.kt`) is the full worked example of the call itself, with the multi-overload fallback
     chain (Android version differences in the AIDL method signature) — port this pattern into
     `TetherHelper.kt`, don't reinvent it.
   - `ShizukuRepository.kt` (`/tmp/delta-ref/data/src/main/kotlin/dev/shadoe/delta/data/shizuku/
     ShizukuRepository.kt`) is the full worked example of Shizuku lifecycle management (binder-received/dead
     listeners, permission request flow, state machine) — port this pattern for Connect's own Shizuku
     onboarding (a "Grant Shizuku Access" button, matching the existing "Grant Bluetooth Permission"/"Grant
     Device Admin" button pattern already in `MainActivity.kt`).

### Current state of the Shizuku setup (as of end of this session)

- Shizuku APK (`v13.6.0.r1086.2650830c-release.apk`) was downloaded to the scratchpad and **installed on the
  phone** (`R5CWB1SSLMJ`) via `adb install -r`. **Not yet activated** — Shizuku needs to actually be started
  (via its own ADB-activation shell script, run once per boot unless the phone is rooted or Shizuku's
  auto-start-via-Wireless-Debugging-pairing feature is set up) before its API is usable. Check Shizuku's own
  in-app instructions (it has a "start via ADB" tab with the exact command, something like `adb shell sh
  /storage/emulated/0/Android/data/moe.shizuku.privileged.api/start.sh`, but confirm the exact path from the
  installed app since it can vary by version) or its GitHub README for the current exact activation command.
- Once Shizuku is running, a REQUESTING app (Connect) must call `Shizuku.requestPermission()` and the user
  approves a one-time dialog (this needs the phone unlocked and the user physically tapping "Allow" **once**
  — unlike the hotspot toggle itself, which then works from the background/locked thereafter). This is a
  one-time setup cost, same category as the `WRITE_SECURE_SETTINGS` adb grant or the device-admin
  activation already done for Lock-on-Leave — acceptable, matches the project's own established pattern for
  these one-time privilege grants.
- The `com.connect.DEBUG_TOGGLE_HOTSPOT` broadcast receiver (temporary, `RECEIVER_EXPORTED`, in
  `SyncForegroundService.kt`'s `onCreate`) is still in place from this session's testing — useful for
  verifying the new Shizuku-based path the same way the old reflection path was tested (`adb shell am
  broadcast -a com.connect.DEBUG_TOGGLE_HOTSPOT --ez enable true`, then check `adb shell ip addr show
  swlan0` for a real `state UP`/assigned IP — **not** `dumpsys wifi | grep SoftApManagers`, which was
  observed to report stale/wrong data this session; `ip addr show swlan0` is the reliable ground truth).
  Remove this receiver once the real GATT-driven request path exists and has been tested through it instead.

### Concrete next steps for Instant Hotspot

1. Activate Shizuku on the phone (adb), grant Connect's Shizuku permission (one tap, needs the phone in
   hand — ask the user or do it yourself if you have a way to interact with the device screen this session).
2. Vendor the AIDL/stub files and add the Shizuku + Refine gradle dependencies to
   `android/app/build.gradle.kts` (or a new module, matching Delta's `system-api-stubs` separation if that's
   cleaner — Connect's existing convention doesn't currently have multiple Gradle modules, so a pragmatic
   call between "new module" vs. "just add the files/deps to the existing `app` module" is yours to make;
   simpler/fewer-moving-parts probably favors just adding to `app` unless build-time hidden-API stub
   processing genuinely requires isolation).
3. Rewrite `android/app/src/main/kotlin/com/connect/features/hotspot/TetherHelper.kt` to use the
   Shizuku/raw-AIDL mechanism instead of the plain `TetheringManager` reflection it currently has (keep the
   existing `ToggleResult` enum/public API shape if reasonable — the GATT layer above it shouldn't need to
   change either way).
4. Add a Shizuku onboarding UI element (mirroring the existing "Grant Bluetooth Permission"/"Grant Device
   Admin" button pattern in `MainActivity.kt`/`ConnectHomeScreen`).
5. Test via the debug broadcast receiver first, confirm real `swlan0` state changes, **then** build the
   actual GATT request path (`hotspot.toggle_request`/`hotspot.status`) that calls this same `TetherHelper`
   function on receipt of an authenticated request — see `docs/ble-hotspot-protocol.md` for what's still
   unbuilt there (the Ed25519-public-key propagation gap, the GATT service itself, `hotspot.auto_config`
   local storage, the WAN-reachability probe, manual-toggle + auto-timeout UI on Mac and tablet). None of
   that GATT/auth/UI work was started this session — only the privileged-call mechanism was the blocker, and
   it's now solved in principle; go build the rest.
6. Update `docs/ble-hotspot-protocol.md`'s "Open blocker" section to describe the Shizuku mechanism as the
   resolution (keep the historical record of what didn't work and why, in the same spirit as the rest of
   this project's documentation — it's been valuable every time this session needed to explain *why* a
   design choice was made, not just what it is).
7. Update the `hotspot_write_secure_settings_insufficient.md` memory file per the note above.

## New ask this session: Android → Mac/tablet clipboard background-read, via Shizuku

Now that Shizuku is being added to the project for hotspot, the user asked: **also use it to fix the
Android-side clipboard background-read restriction**, which was previously given up on. Context (from
`schema/message-types.md`'s `clipboard.update` row and `android/app/src/main/kotlin/com/connect/features/
clipboard/ClipboardSyncManager.kt`'s doc comment, both already in the repo — read them): since Android 10, a
background app — even a foreground `Service` — is denied `ClipboardManager.getPrimaryClip()` reads unless
the app currently has window focus. An `AccessibilityService`-based workaround was tried earlier in this
project's history and confirmed live on a real Samsung/One UI device **not** to grant the exemption.
Practical effect documented today: Android → mesh clipboard sync only reliably fires while Connect's own UI
is foregrounded; Mac→Android and Mac↔Mac are unaffected.

This is a **new research task, not a known-solved one** — unlike the hotspot mechanism above, nobody has
confirmed Shizuku fixes this specific restriction in this session. Investigate whether the same
technique (a raw hidden `IClipboard`/`ClipboardManager` AIDL interface, obtained via
`ShizukuBinderWrapper`/`SystemServiceHelper.getSystemService("clipboard")`, called with a spoofed/shell
caller identity the same way `ITetheringConnector` was) can read the clipboard from the background without
focus. Leads to pull on:
- Android's hidden `IClipboard.aidl`/`IClipboard.getPrimaryClip(...)` interface (framework-internal, same
  category of hidden API as `ITetheringConnector`/`IWifiManager` above — check AOSP source via
  `cs.android.com` search for `IClipboard.aidl` under `frameworks/base/core/java/android/content/`).
  Signature includes a caller-attribution parameter (package name/UID/user id) similar to the tethering
  case — the same "call as shell, assert a trusted caller identity" trick may or may not apply, since the
  clipboard-focus check might be enforced differently (some Android versions check the *real* calling UID's
  actual foreground-window state via `WindowManagerInternal`/`ActivityManagerInternal`, in which case
  spoofing the package name alone wouldn't help — calling *as shell* might work if shell itself is treated
  as always-focused/exempt, similar to how shell bypassed the tethering check; this needs live testing, not
  assumption).
- Whether any other clipboard-manager-style automation app (Tasker plugins, clipboard-manager apps on the
  Play Store that claim background clipboard capture) has published a working Shizuku-based technique — the
  same kind of "find the real prior art" research that cracked the hotspot problem should be applied here
  too, rather than reasoning from the framework source alone.
- If a working technique is found, wire it into `ClipboardSyncManager.kt` as an alternative read path when
  Shizuku is available/granted, falling back to the current foreground-only behavior when it isn't (Shizuku
  is optional/user-granted, not a hard dependency — the app must keep working without it, same as every
  other optional-permission feature in this codebase, e.g. Bluetooth proximity gracefully no-ops without its
  permission too).
- Update `schema/message-types.md`'s `clipboard.update` row and `ClipboardSyncManager.kt`'s doc comment to
  reflect the new capability (and its Shizuku-conditional nature) once implemented — per this repo's
  `CLAUDE.md` convention, don't leave the docs describing the old, now-superseded limitation.

## Practical reminders carried forward

- Both apps run from source; see device-specific launch commands above.
- `xcodegen generate` after any Swift file add/remove; hand-editing the `.pbxproj` is wrong.
- Wireless adb to the tablet drops intermittently — reconnect, don't assume a real bug.
- CI (`.github/workflows/mac.yml`, `android.yml`) builds/tests on push/PR touching `mac/**`/`android/**`/
  `schema/**` — keep both green.
- **Verify platform capabilities empirically, on real hardware, before architecting a feature around an
  assumed one** — this lesson from the original handoff was reconfirmed hard, twice, this session (the
  clipboard restriction the *first* time around, and Android 16's `TETHER_PRIVILEGED` lockdown this time).
  It is worth internalizing rather than re-learning a third time.
- When a promising-looking approach fails, don't declare a dead end from first-principles reasoning alone —
  this session's actual breakthrough (Delta/Shizuku) came only from searching for **real, currently-shipping
  software that already solves the identical problem** and reading its actual source, after abstract
  reasoning ("shell lacks the permission, so nothing can work") turned out to be based on testing the wrong
  code path. If a wall looks hard, look for prior art before concluding it's actually a wall.
