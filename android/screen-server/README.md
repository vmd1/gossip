# On-device capture server (fast-follow, not implemented in this unit)

This directory is a placeholder for scrcpy-style approach (a) from the Wave 2
"Screen mirroring via ADB/scrcpy" unit: a small Java/Kotlin class, `adb push`-ed
to the device and run via `adb shell CLASSPATH=/data/local/tmp/screen-server.jar
app_process / com.connect.screenserver.Server`, that captures the display with
`MediaCodec` H.264 encoding and streams the raw elementary stream back over a
socket that the Mac `adb forward`s to a local TCP port — exactly scrcpy's own
architecture (Genymobile/scrcpy, Apache 2.0).

**This unit shipped with approach (b) instead** (`adb exec-out screenrecord
--output-format=h264 -`, see `mac/Connect/Features/ScreenMirror/ADBClient.swift`).
Approach (a) is the better long-term architecture — lower latency, no
`screenrecord` 3-minute/`--time-limit` quirks, and a socket stream instead of
re-spawning a process — but a correct capture server is substantial work on
its own (packaging a `CLASSPATH`-runnable jar, driving `MediaCodec`'s
async/Surface-input API by hand, framing the output for the forwarded socket,
handling `app_process`'s dalvik-cache permission quirks on newer non-rooted
Android — see below) and was judged too large to also land, verified, within
this unit's scope. Tracking it here rather than as a stub implementation so
the next unit that picks this up starts from real findings, not a half-built
server nobody has run.

## Why approach (b) was chosen for v1

`adb exec-out screenrecord --output-format=h264 -` was verified working
end-to-end against a real device (Samsung SM-S711B, Android Platform Tools
37.0.1) with no code to write or push:

```
$ adb exec-out screenrecord --output-format=h264 --time-limit=3 - > test.h264
$ ffprobe -show_streams test.h264
codec_name=h264, profile=High, width=1080, height=2340, pix_fmt=yuv420p, avg_frame_rate=25/1
```

2.2MB of valid Annex-B H.264 for 3 seconds, matching the device's real `wm
size` (1080x2340). That's a legitimate, if higher-latency and higher-overhead,
capture mechanism — `screenrecord` is designed for bug-report recording, not
low-latency interactive mirroring, so it has more encoder start-up latency and
a default 180s cap (lifted here via `--time-limit 0`) than a purpose-built
capture server would.

## Important finding: `app_process` needs write access to `/data/dalvik-cache`

While investigating approach (a) on the connected test device, a plain

```
$ adb shell app_process --help
Error changing dalvik-cache ownership : Permission denied
```

failed immediately — `app_process` invoked bare over `adb shell` tries to
touch `/data/dalvik-cache` and fails without additional setup on this
(non-rooted) device/Android version. scrcpy's actual server launch avoids this
specific failure mode by invoking `app_process` with an explicit `CLASSPATH`
pointing at a pushed jar in `/data/local/tmp` rather than bare, plus a
`-Djava.class.path=...` per its own launch script — that path was not
attempted here due to time, so it remains untested rather than confirmed
broken. Whoever picks up approach (a) should start by reproducing scrcpy's
exact `app_process` invocation (see `Genymobile/scrcpy`'s `Server.java`
launch path in `SCRCPY_SERVER_PATH`/`local/tmp` handling) rather than a bare
`app_process --help` sanity check, which is a red herring for this failure
mode.

## Important finding: the MediaProjection consent dialog

This unit's task brief flagged a specific risk worth resolving either way:
does ADB-mediated capture (whether via `screenrecord` or a `scrcpy`-style
server) trigger Android's normal `MediaProjection` "Start recording or
casting?" consent dialog?

**Empirical answer from this session: no.** `adb exec-out screenrecord
--output-format=h264 -t 3 -` captured the phone's screen and produced valid
H.264 output with **no on-device dialog, prompt, or visible UI change** during
capture — confirmed by running it and observing the device screen was
untouched by any system dialog. `screenrecord` is a `system`/`shell`-privileged
binary; captures invoked through it (and, by the same mechanism, through
`adb shell`-launched code generally) run with capture privileges the OS
already grants to the shell/system UID, not as a third-party app calling
`MediaProjectionManager.createScreenCaptureIntent()` from application code —
which is what triggers the per-session consent dialog for a normal app.

This is consistent with (and confirms, for this specific device/OS revision)
the premise behind risk #2 in the project's risk list: ADB-mediated capture
avoids the consent-dialog UX problem a "normal" in-app screen-mirroring
feature would have. It does **not** by itself prove a scrcpy-style
`MediaProjection`-based server invoked via `app_process` would behave
identically — that path was not reached (blocked by the dalvik-cache issue
above) — but `screenrecord`'s behavior is strong evidence for the same
conclusion, since it exercises the same "shell-privileged capture, no app-side
consent" trust boundary that scrcpy's own approach relies on. No project risk
needs walking back based on what was actually tested.
