# Gossip

[![License: Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)
[![Mac](https://github.com/vmd1/gossip/actions/workflows/mac-test.yml/badge.svg)](https://github.com/vmd1/gossip/actions/workflows/mac-test.yml)
[![Android](https://github.com/vmd1/gossip/actions/workflows/android-test.yml/badge.svg)](https://github.com/vmd1/gossip/actions/workflows/android-test.yml)

Gossip is open source under the [Apache 2.0 license](LICENSE) — issues and PRs welcome.

Mac ↔ Android continuity app (formerly "Connect"): notification mirroring (with inline reply),
clipboard sync, Do Not Disturb/Focus sync, media/Now Playing remote control, screen mirroring, and
multi-device mesh trust (pair once, propagate everywhere). See `ROADMAP.md` for the
full feature list mapped against Apple Continuity, and `docs/architecture.md` for how the two apps
fit together.

Mac app is Swift (`mac/Gossip`), Android app is Kotlin
(`android/app/src/main/kotlin/dev/vmd1/gossip`). The two share no compiler or code — `schema/message-types.md`
is the single source of truth keeping them in sync.

## Installing

Prebuilt binaries are attached to every [GitHub Release](https://github.com/vmd1/gossip/releases/latest):

- **Mac** (Apple Silicon only): download `Gossip-Mac-AppleSilicon.zip`, unzip, and move
  `Gossip.app` to `/Applications`. It's ad-hoc signed, not notarized, so Gatekeeper will block the
  first launch — right-click the app and choose **Open** (or run `xattr -cr Gossip.app` in
  Terminal), then launch normally from then on.
- **Android**: download `Gossip-Android-universal.apk` and install it (you'll need to allow
  "install unknown apps" for whichever app you downloaded it with). It's debug-signed, not a Play
  Store build, so Android will warn about an unverified app — expected for a side-loaded build.

The first time Gossip runs from `/Applications` (or `~/Applications`) it also adds a small **Device Mirroring**
app next to itself, so you can open the list of paired phones and tablets and start mirroring from Spotlight or
Launchpad. It ships inside `Gossip.app`, so there is nothing extra to download; turn it off under Gossip's
Settings → Apps (deleting the app from Applications removes it).

### Universal Control (Mac mouse and keyboard on your Android devices)

Turn it on under Settings → Universal Control on both devices, then **Arrange Devices…** to place each
device next to your Mac's display and push the cursor off that edge. It needs:

- **Mac:** *Accessibility* and *Input Monitoring* (System Settings → Privacy & Security; the Settings pane has
  buttons that open them). macOS ties these grants to the app's code signature, so a build signed ad hoc loses
  them on every update. Releases and local builds are therefore signed with one stable self-signed identity,
  `gossip.vmd1.dev` (not a paid Developer ID, so Gatekeeper still blocks a downloaded copy until you choose
  "Open Anyway" in System Settings → Privacy & Security). For local builds run `mac/scripts/create-signing-cert.sh`
  once (creates the key in `~/.gossip-signing/`, imports it into your login keychain and writes
  `mac/Config/Signing.local.xcconfig`), then `xcodegen generate`. Back up `~/.gossip-signing/`: losing the key means
  every user re-grants once. The release workflow signs with the same key, kept in the `release` GitHub
  environment (restricted to `main`; load it with `mac/scripts/set-ci-signing-secrets.sh`). Never commit the key.
  Gossip is not sandboxed (a sandboxed app cannot capture input), which also means a Mac that used an older,
  sandboxed build gets a new identity: choose "Forget" for the old Mac on each Android device and pair again.
- **Android device:** Shizuku running (the virtual mouse and keyboard are created at shell privilege). The
  device must be directly connected to the Mac over the LAN (a device reachable only through the mesh, shown
  with a blue icon, cannot be controlled).
- Emergency exit: Control-Option-Command-Esc returns the cursor to the Mac. Password fields hide keystrokes
  from every app on macOS ("secure input"), so typing into them from the Mac does not work.

To pair the two: open Gossip on the Mac, click the menu bar icon, and choose **Pair New Device…**
to show a QR code. On Android, tap **Pair New Device** and scan it. Once paired, either device can
also generate its own QR (**Show QR to Pair**, Android) for pairing directly with another Android
device without going through a Mac.

Building from source: Mac needs [XcodeGen](https://github.com/yonaskolb/XcodeGen) — run
`xcodegen generate` inside `mac/` to produce `Gossip.xcodeproj`, then build/run it in Xcode.
Android is a standard Gradle project — `cd android && ./gradlew assembleDebug` (requires JDK 17).

## Docs

- `docs/architecture.md` — how the two apps fit together
- `docs/wire-protocol.md` — byte-level framing over the socket
- `schema/message-types.md` — the message type registry
- `docs/adr/` — architecture decision records
