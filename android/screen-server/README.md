# On-device capture server (unit 11: vendored scrcpy)

This directory vendors [Genymobile/scrcpy](https://github.com/Genymobile/scrcpy)'s
real, prebuilt `scrcpy-server.jar` (release `v4.1`, Apache 2.0 — see
`LICENSE.scrcpy`) and uses it, unmodified, as the on-device capture component
for screen mirroring. This replaces the `adb exec-out screenrecord` stopgap
that unit 7 shipped with (see "History" below).

## Why approach (a) — real vendoring, not a from-scratch server

The task brief offered two options: vendor scrcpy's actual server jar and
speak its real protocol, or write a smaller from-scratch `MediaProjection`/
`MediaCodec` capture server with a custom wire format. Vendoring was chosen
because:

- scrcpy's server is battle-tested and already solves the hard, fiddly parts
  (driving `MediaCodec`'s async/Surface-input API correctly, handling display
  rotation/resize, working around device-specific quirks) that a from-scratch
  server would have to re-solve from zero.
- Its **`raw_stream=true`** "standalone server" mode (see below) turns out to
  produce *exactly* the same wire format the old `screenrecord` stopgap did —
  a bare Annex-B H.264 elementary stream, no extra framing — so the existing,
  already-working `H264Decoder.swift` needed **zero changes**. Only the
  transport layer (how bytes get from the phone to the Mac) changed.
- It was fully verified end-to-end against the real connected device in this
  session (see "Verification" below), which the task explicitly said should
  decide the approach over an untested alternative.

The one thing this approach depends on that a from-scratch server wouldn't:
tracking scrcpy's server/protocol version. That's an accepted, documented
tradeoff — the vendored jar is pinned to `v4.1` and the Mac client hardcodes
that version string when launching it (`ADBClient.serverVersion`).

## What's here

- `scrcpy-server.jar` — scrcpy's real `scrcpy-server-v4.1` release asset,
  downloaded from
  `https://github.com/Genymobile/scrcpy/releases/download/v4.1/scrcpy-server-v4.1`
  and renamed. SHA-256 `deacb991ed2509715160ffdc7907e47b4160eb30d1566217e9047fd5b8850ca`,
  verified against scrcpy's published `SHA256SUMS.txt` for the `v4.1` release
  before committing it here.
- `LICENSE.scrcpy` — scrcpy's Apache License 2.0, copied verbatim from the
  `v4.1` tag. Required attribution for redistributing their binary.

The jar is consumed by `mac/Connect/Features/ScreenMirror/ADBClient.swift`
(`ensureScrcpyServerPushed`/`startScrcpyCapture`), which locates it relative
to its own source file (`#filePath` + four `deletingLastPathComponent()` calls
up to the repo root) rather than as a bundled `Connect.app` resource — the
same "assume a repo checkout, not a distributed binary" pragmatism already
used for the `adb`-on-PATH assumption elsewhere in that file. Bundling it as a
proper Xcode "Copy Bundle Resources" phase (the project currently has none at
all — no `PBXResourcesBuildPhase` in `Connect.xcodeproj`) is a packaging
follow-up for when this ships to users without a repo checkout.

## How it's launched

```
adb push android/screen-server/scrcpy-server.jar /data/local/tmp/connect-scrcpy-server.jar   # only if size differs from what's already there
adb forward tcp:<free local port> localabstract:scrcpy
adb shell CLASSPATH=/data/local/tmp/connect-scrcpy-server.jar app_process / com.genymobile.scrcpy.Server 4.1 \
    log_level=info audio=false control=false cleanup=false raw_stream=true tunnel_forward=true \
    max_size=<optional> video_bit_rate=<bitrate>
```

This is scrcpy's own documented ["standalone server"](https://github.com/Genymobile/scrcpy/blob/v4.1/doc/develop.md#standalone-server)
mode (`doc/develop.md`), used here as our actual production transport rather
than just a manual-testing curiosity:

- `raw_stream=true` disables scrcpy's own device-metadata / frame-meta-header
  / dummy-byte / stream-meta framing, leaving nothing but a continuous Annex-B
  H.264 elementary stream on the socket — bit-for-bit compatible with what
  `H264Decoder.swift` already parses.
- `tunnel_forward=true` makes the on-device server *listen* on its local
  abstract socket and wait for `adb forward` to bridge a connection in,
  rather than connecting out itself (`adb reverse`, scrcpy's default for its
  own GUI client). `adb forward` is simpler to drive one-shot from Swift than
  standing up a listening `NWListener` and coordinating `adb reverse`
  ourselves, and was the mode actually verified working end-to-end.
- `cleanup=false` — **important deviation from scrcpy's own default.**
  scrcpy's `cleanup=true` deletes whatever jar it was launched from
  (`Server.SERVER_PATH`, derived from the `CLASSPATH` we pass) when the
  server process exits. That's fine for the real scrcpy client, which
  re-pushes its jar every session anyway, but it directly defeats this unit's
  "check a version marker so you don't re-push every session" requirement —
  with `cleanup=true`, *every* mirror session would re-push the ~720KB jar.
  `cleanup=false` leaves it at `/data/local/tmp/connect-scrcpy-server.jar`
  between sessions; `ADBClient.ensureScrcpyServerPushed` then does a cheap
  `stat`-based size comparison and only re-pushes on a mismatch (e.g. a
  future scrcpy version bump).
- No `scid` param is passed. **This is not arbitrary** — scrcpy's on-device
  `DesktopConnection.getSocketName(int scid)` (in
  `server/.../device/DesktopConnection.java`) returns the literal string
  `"scrcpy"` when `scid == -1` (the default when the param is omitted), and
  `"scrcpy_" + String.format("%08x", scid)` otherwise. `adb forward`'s target
  abstract socket name must match whatever the device server actually opened,
  or `adb` will accept the local TCP connection, fail to bridge it to a
  socket nobody's listening on, and immediately tear it down again (see the
  "abstract socket name mismatch" pitfall below) — so
  `ADBClient.deviceSocketName` is hardcoded to `"scrcpy"` to match the
  no-`scid` default exactly.

## The dalvik-cache fix (from unit 7's finding)

Unit 7's finding was:

```
$ adb shell app_process --help
Error changing dalvik-cache ownership : Permission denied
```

This unit confirms the fix that finding predicted but didn't attempt:
`app_process` invoked **bare** (no `CLASSPATH`, no explicit class to run)
tries to write to `/data/dalvik-cache` and fails on this non-rooted device.
Invoked the way scrcpy's own launcher does it —
`CLASSPATH=/data/local/tmp/<jar> app_process / com.genymobile.scrcpy.Server ...`
— it works with **no dalvik-cache error at all**, verified repeatedly against
the real device (Samsung SM-S711B, Android 16) in this session. The `/` after
`app_process` is scrcpy's own convention (an unused working-directory
argument `app_process` expects positionally); it is not meaningful here and
was kept only for exact parity with scrcpy's own invocation.

## Pitfall discovered in this session: abstract socket name mismatch looks like a startup race

Early in verification, `ADBClient` used a custom device socket name
(`"scrcpy_connect"`) instead of scrcpy's actual default (`"scrcpy"`, see
above). Symptom: `adb shell ps` confirmed `app_process` was running, `adb
forward --list` showed the forward was set up, and `NWConnection` reached
`.ready` (a successful *local* TCP handshake) — but the very first `receive()`
call always returned a clean, error-free EOF with zero bytes, on every retry,
indefinitely. This looked exactly like the well-known "connected before the
server called `accept()`" startup race, and the fix that race needs (retry
the whole connection attempt, not just the state-machine transition to
`.ready`) is now in `ADBClient.connectWithRetry` and is still correct/needed
for the *real* race. But it wasn't sufficient here, because the actual bug
was different: `adb forward`'s local TCP listener will accept a connection
and report success locally *before* it confirms anything is listening on the
device-side abstract socket name — if nothing ever will be (wrong name), you
get the same "accepted then instant EOF" symptom forever, not just on the
first few attempts. Anyone extending this should treat "EOF immediately after
every single retry, never any data at all" as a sign to double check the
abstract socket name against what the device process actually opened
(`adb shell cat /proc/net/unix | grep scrcpy` while it's running is a fast way
to check), not just assume it's a slow-server timing issue.

## MediaProjection consent dialog

Confirmed **no** consent dialog for the vendored-scrcpy path either, for the
same reason unit 7 documented for `screenrecord`: `app_process` launched via
`adb shell` runs with the shell/system UID's existing capture privileges, not
as a third-party app calling
`MediaProjectionManager.createScreenCaptureIntent()` — which is the only path
that triggers Android's per-session "Start recording or casting?" prompt.
Verified by observation during every capture run in this session: no dialog,
prompt, or visible UI change on the device screen.

## Verification performed in this session (real device: Samsung SM-S711B, Android 16, Platform Tools via Homebrew `android-commandlinetools`)

1. **`adb devices`**: device `R5CWB1SSLMJ` connected and authorized
   throughout this session.
2. **Push + launch confirmed for real**: `adb push` of `scrcpy-server.jar`
   succeeded; `adb shell CLASSPATH=... app_process ...` launched with no
   dalvik-cache error; `adb shell ps -A | grep app_process` showed the
   process running while a capture was in progress.
3. **Real H.264 bytes pulled from the forwarded socket, at two levels**:
   - A standalone Python socket script (not app code) connected to the
     `adb forward`ed port and captured 1,331,278 bytes in ~4s, verified with
     `ffprobe -show_streams` as `codec_name=h264, profile=High, 590x1280,
     pix_fmt=yuv420p` (note: 590x1280, not the phone's native 1080x2340 —
     `max_size=1280` was passed, and scrcpy scales to fit within that bound).
   - **The actual production Swift code path** — a small `swiftc`-compiled
     harness (not shipped; used only for this verification) that calls
     `ADBClient().startScrcpyCapture(...)` exactly as `ScreenMirrorController`
     does, dumping the bytes `onData` delivers to a file — produced a second,
     independently-captured Annex-B H.264 stream (device screen was static/
     locked for part of this run, hence small delta-frame sizes — still
     structurally valid), also confirmed via `ffprobe -show_streams` as
     `codec_name=h264, profile=High, 590x1280`. First bytes:
     `00 00 00 01 67 64 00 20 ...` (start code + SPS NAL) /
     `00 00 00 01 68 ...` (PPS) / `00 00 00 01 65 ...` (IDR slice) — exactly
     the Annex-B framing `H264Decoder.swift` expects, unchanged.
4. **`cd mac && xcodebuild ... build` and `... test`**: both succeeded (38/38
   tests passed) against the final code.
5. **`cd android && ./gradlew assembleDebug` and `./gradlew test`**: both
   succeeded. (`ANDROID_HOME` had to be set explicitly in this environment —
   `/opt/homebrew/share/android-commandlinetools` — `local.properties` isn't
   checked in.) The vendored jar lives outside any Gradle source set
   (`android/screen-server/` is not referenced by `settings.gradle.kts`), so
   it has no effect on the main app's build either way.

### What was *not* verified

Same honesty bar unit 7 held itself to: there is no interactive display in
this environment, so the Mac-side rendered `ScreenMirrorWindow` (the
`AVSampleBufferDisplayLayer` actually painting frames on screen, or on-screen
tap/swipe input forwarding) was not visually confirmed. What *was* verified,
directly, is everything upstream of rendering: real on-device capture, real
byte-valid H.264 delivered through the real forwarded-socket transport, into
the real `ADBClient` production code path. `H264Decoder.swift` itself is
unchanged from the (already-shipped, already-reasoned-about) unit 7
implementation, so its own correctness is inherited rather than re-verified
here.

## Input control

Left unchanged (`adb shell input tap/swipe/keyevent/text`), per the task's
own guidance not to regress working functionality without a documented
reason. scrcpy's real client uses its own binary control-socket protocol
(lower latency, supports more input types), but swapping to it is a
larger, separable change with its own protocol surface to verify — not
attempted in this unit.

## History

- Unit 7 (M7, PR #16) shipped `adb exec-out screenrecord --output-format=h264
  -`, a real but admittedly stopgap capture mechanism, and left this
  directory as a placeholder documenting *why* a real capture server wasn't
  attempted yet (dalvik-cache blocker hit and not resolved, time-boxed out of
  scope). Its findings are preserved above where this unit builds on or
  confirms them.
- Unit 11 (this unit) replaces that stopgap with the vendored server
  documented here.
