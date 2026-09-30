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
