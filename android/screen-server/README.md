# On-device screen capture (scrcpy server via Shizuku)

**Status (2026-10-01): Android side implemented and verified on Android 16 and Android 12
emulators, plus one smoke run on a real Samsung SM-S711B (Android 16). Mac viewer not built.**

Gossip bundles the upstream **scrcpy server** (Genymobile/scrcpy v4.1, Apache 2.0,
`app/src/main/assets/scrcpy-server-v4.1.jar`, SHA-256
`deacb991ed2509715160ffdc7907e47b4160eb30d1566217e9047fd5b8850cae`, matches the release's
`SHA256SUMS.txt`), launches it at shell UID through **Shizuku's `newProcess`**, and bridges its
video + control streams to one viewer over an authenticated **WebSocket**. The viewer needs no
`adb`/`scrcpy`. Protocol: `screen.start`/`stop`/`ready`/`error` in `schema/message-types.md`.

The existing `adb exec-out screenrecord` pipeline (`mac/.../ScreenMirror/ADBClient.swift`,
"approach (b)") is untouched and **remains the working fallback** until a Mac viewer exists.

## Architecture (and why it isn't the one we planned)

```
Mac viewer ──WebSocket(token)──▶ ScreenBridge (Gossip app, untrusted_app UID)
                                      │ Shizuku binder stdio  (framed: video / control / device-msg)
                                      ▼
                           ShellRelay  (app_process from Gossip's own APK, shell UID)
                                      │ abstract unix socket scrcpy_<scid>   (shell→shell: allowed)
                                      ▼
                           scrcpy Server (app_process from the jar, shell UID)  ── MediaCodec H.264
```

The plan was "app connects to the server's local socket". **That does not work**: SELinux denies
it, in both directions (details below), so a tiny shell-UID relay (`ShellRelay.java`, plain Java,
no Kotlin stdlib, loaded from the app's own `base.apk`, so no extra artifact) dials the socket
and multiplexes it over Shizuku's stdio, which *is* a private binder pipe to the app. Loopback TCP
would have been simpler but any app on the phone could connect to it and mirror/inject.

## What was verified, in the order the spike was run

Environment: AVDs `a16` (`system-images;android-36;google_apis;arm64-v8a`) and `a12`
(`android-32;google_apis;arm64-v8a`), Pixel 6 profile, emulator 37.2.12, run headless
(`-no-window -gpu swiftshader_indirect`). **arm64, not x86_64** — the dev machine is an Apple
Silicon Mac, where x86_64 images don't run accelerated. Gossip built with
`./gradlew :app:assembleDebug` (unchanged toolchain) and installed as the real app.

### 1. Bare `app_process` is a red herring — confirmed on both
```
$ adb shell app_process --help
Error changing dalvik-cache ownership : Permission denied          # Android 16 AND Android 12
```

### 2. scrcpy's real launch via raw `adb shell` — works on both
```
$ adb push scrcpy-server-v4.1 /data/local/tmp/scrcpy-server.jar
$ adb shell CLASSPATH=/data/local/tmp/scrcpy-server.jar app_process / com.genymobile.scrcpy.Server \
      4.1 scid=00000001 tunnel_forward=true audio=false control=true cleanup=false max_size=1280
[server] INFO: Device: [Google] google sdk_gphone64_arm64 (Android 16)    # / (Android 12)
$ adb forward tcp:27183 localabstract:scrcpy_00000001   # then connect video + control sockets
```
So the "Permission denied" `/data/dalvik-cache` failure is specific to *bare* `app_process`; an
explicit `CLASSPATH` launch is fine. The server only starts streaming once **both** the video and
control sockets are connected. First video connection yields: 1 dummy byte, 64-byte device name,
`h264` codec id, then a session packet, then packets.

### 3. Shizuku mainline works — no fork needed (both versions)
Activation on both emulators (no wireless debugging needed; Shizuku 13.6.0 no longer writes
`start.sh`, it execs its native starter directly):
```
$ P=$(adb shell pm path moe.shizuku.privileged.api | sed 's/package://; s|/base.apk||')
$ adb shell "$P/lib/arm64/libshizuku.so"
info: starting server...  info: shizuku_server pid is 5465  info: shizuku_starter exit with 0
$ adb shell ps -A | grep shizuku_server    →  shell ... shizuku_server
```
**Build used: mainline `RikkaApps/Shizuku` v13.6.0 (`shizuku-v13.6.0.r1086.2650830c-release.apk`)
on both Android 16 and Android 12; the server reports "Version 13.5, adb".** Gossip's own
dependency is `dev.rikka.shizuku:api/provider:13.1.5` (unchanged). Gossip's existing onboarding
"Shizuku → Grant" button produced the normal "Allow Gossip to access Shizuku?" dialog on both.
Caveat: the brief warned mainline has Android 16 bugs. None showed up for what this feature
uses (`newProcess` + stdio); I did **not** re-test the other Shizuku consumers (Instant Hotspot's
tethering AIDL, clipboard binder) here, so that warning may still apply to them. No Android
16 fork was evaluated because nothing forced it. Shizuku must be re-activated after every
emulator/phone reboot (not tested across a reboot).

### 4. Launching via Shizuku `newProcess` from inside Gossip — works, but the socket is blocked
`ShizukuShell.exec` reflects into `Shizuku.newProcess` (made private in API 13; same as every
consumer). The jar is streamed into `sh -c 'cat > /data/local/tmp/...'` over stdin, so the app
needs no storage permission. The server launched fine at shell UID (`Device:` line in logcat).
Then the app tried to connect to its socket:
```
java.io.IOException: Permission denied   at LocalSocketImpl.connectLocal
avc: denied { connectto } for path=@scrcpy_2a5bb225 scontext=u:r:untrusted_app:s0 tcontext=u:r:shell:s0 tclass=unix_stream_socket permissive=0
```
Reverse mode (`tunnel_forward=false`, app listens, server dials in) fails the other way:
```
avc: denied { connectto } scontext=u:r:shell:s0 tcontext=u:r:untrusted_app:s0:... tclass=unix_stream_socket
```
Both captured on **Android 16**. On Android 12 I did not separately reproduce the denial (the relay
design was already in place and works there); I'm not claiming it from evidence.

### 5. Via the relay: valid H.264 + control injection — both versions
`ScreenBridge` is driven by `ws_test_client.py` (stdlib only, in this directory), which stands in
for the unbuilt Mac viewer. Real output, final build:
```
# Android 16                                          # Android 12
screen.ready after 1.1s: port=36561                    screen.ready after 1.1s: port=39531
wrong token rejected: True                             wrong token rejected: True
stream header: {codec h264, 576x1280, sdk_gphone64…}   stream header: {codec h264, 576x1280, sdk_gphone64…}
second viewer refused: True                            second viewer refused: True
wakefulness before: Awake                              wakefulness before: Awake
wakefulness after POWER: Asleep                        wakefulness after POWER: Asleep
wakefulness after POWER #2: Awake                      wakefulness after POWER #2: Awake
video: 50 packets, 216556 B, key frames=1              video: 48 packets, 403968 B, key frames=1
leftover shell app_process after stop: none            leftover shell app_process after stop: none
$ ffprobe -show_streams bridge16.h264                  $ ffprobe -show_streams bridge12.h264
codec_name=h264 profile=Constrained Baseline           codec_name=h264 profile=Constrained Baseline
width=576 height=1280 pix_fmt=yuv420p                  width=576 height=1280 pix_fmt=yuv420p
```
(1080x2400 screen, `max_size=1280` → 576x1280.) The control channel is real: POWER key
injected through the WebSocket → scrcpy control socket toggled `mWakefulness`
Awake→Asleep→Awake, read back with `dumpsys power`. The late-attach path works too: the
server starts at `screen.start`, the viewer attaches later, and the bridge replays the cached
config packet and sends scrcpy `RESET_VIDEO` (control type 17), yielding a key frame even though
the emulator's screen is static (`key frames=1`).

### 6. No MediaProjection consent dialog — confirmed for the scrcpy server (both versions)
During a live capture: screenshot of the Android 16 screen showed the plain launcher (no
"Start recording or casting?" dialog), `dumpsys media_projection` listed no projections, no
consent window, and both shell processes were running. Same `dumpsys media_projection` result
(empty) on Android 12 during a session. This closes the open point from the screenrecord-era
finding: a scrcpy-style server at shell UID needs no consent either.

### 7. Teardown / leaks
`force-stop` of Gossip mid-session: both shell-UID processes were gone within 4 s (relay exits on
stdin EOF → closes sockets → server exits). Viewer disconnect and `screen.stop` also clear them
(`leftover shell app_process after stop: none` above). Unit tests (`ScreenMirrorStateTest`, 9
cases, JVM) cover start/stop idempotency, duplicate/late/out-of-order messages, supersede,
Shizuku-unavailable and capture-failure replies; the full suite is 64 tests, 0 failures. Writing
the failure-path test found and fixed a real bug (`screen.error` swallowed because
`close()`'s `onEnded` cleared the session before `fail()` ran).

## scrcpy 4.1 stream format notes (differs from older docs — verified empirically)
Video socket: `u8 dummy` (forward tunnel only) · `64B device name` · `4B codec id ("h264")`, then
a sequence of either **session packets** (`u32 0x80000000`, `u32 width`, `u32 height`; a new one
is sent on rotation/`RESET_VIDEO`) or **media packets** (`u64 pts/flags`, `u32 size`, payload).
Observed flags: config (SPS/PPS) = bit 62 (`0x4000…`), key frame = bit 61 (`0x2000…`). The
bridge re-frames these into WebSocket messages (`ScreenBridge.kt` doc comment). Because
scrcpy's wire format isn't a stable API, the jar is pinned and must not be auto-updated; a
version bump means re-verifying this section.

### 8. Real-hardware smoke run (Samsung SM-S711B, Android 16, mainline Shizuku already running)
Debug build sideloaded with `adb install -r` (pairing preserved), then `ws_test_client.py
--seconds 5` (no input injection):
```
screen.ready after 3.9s: port=46261
wrong token rejected: True      second viewer refused: True
stream header: {'codec': 'h264', 'width': 590, 'height': 1280, 'deviceName': 'SM-S711B'}
video: 60 packets, 174122 bytes, key frames=1, size msgs=[(590, 1280), (590, 1280)]
leftover shell app_process after stop: none
$ ffprobe: codec_name=h264 profile=High width=590 height=1280
```
Hardware encoder gives High profile (the emulator's software encoder gave Constrained Baseline).
`screen.ready` took 3.9 s here vs 1.1 s on the emulators (cold start, includes first-run jar push).
Still not covered on hardware: control injection, sustained motion, latency, rotation.

## What is NOT proven / open
- **Mostly emulator-verified; only the smoke run above is on hardware.** SurfaceFlinger/virtual-display/encoder behavior on a
  real phone (vendor encoders, DRM/secure layers, rotation, HDR, display cutouts) can differ;
  the emulator uses the software `c2.android.avc.encoder` and a static screen, so sustained
  motion, bitrate behavior, and latency were **not** measured. The "first video at +4.5s" the test
  client prints includes its own wrong-token/second-viewer test steps; it is not a latency number.
  (`screen.ready` itself arrives ~1.1 s after `screen.start`.)
- **Mac viewer not built** (scrcpy protocol client, H.264 decode/render, input mapping), so the
  full Mac↔Android path and the `screen.start`-over-the-mesh exchange were exercised only via a
  debug broadcast that dispatches the envelope locally; `screen.ready` was read from logcat
  (debug builds log the token), not received over Noise by a real peer.
- **Video is not encrypted on the WebSocket.** Auth is a 256-bit per-session token delivered
  inside the Noise-encrypted mesh, constant-time compared, single viewer; but the WebSocket
  payload (screen contents + control) is plaintext on the LAN. Reusing the Noise trust
  end-to-end (Noise-over-WebSocket, or an AEAD key derived from the Noise session and delivered
  in `screen.ready`) was out of scope for one pass and is the main follow-up before shipping.
  The listener also binds all interfaces (any LAN host can *connect* — only the token gates it).
- Shizuku must be running (re-activate after reboot) and granted; otherwise `screen.error
  shizuku_unavailable`. Not tested: reboot persistence, Shizuku killed mid-session, Android
  13–15, multi-display, `max_size` rotation mid-stream (a session packet is forwarded but I did
  not rotate the emulator), a slow viewer (writes block the video thread; no frame dropping yet).
- `/data/local/tmp/gossip-scrcpy-server.jar` is left on the device (733 KB, overwritten each
  session); not cleaned up.
- If this approach fails on a real device, approach (b) (`screenrecord`) remains the fallback.

## Earlier findings still valid (screenrecord era, real Samsung SM-S711B, platform-tools 37.0.1)
`adb exec-out screenrecord --output-format=h264 --time-limit=3 -` → valid Annex-B H.264,
`codec_name=h264, profile=High, width=1080, height=2340, pix_fmt=yuv420p`, no on-device
dialog. That shipped path is higher-latency (encoder start-up, process respawn, 3-minute cap
lifted via `--time-limit 0`).
