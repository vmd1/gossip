# Gossip

[![License: Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)
[![Mac](https://github.com/vmd1/gossip/actions/workflows/mac.yml/badge.svg)](https://github.com/vmd1/gossip/actions/workflows/mac.yml)
[![Android](https://github.com/vmd1/gossip/actions/workflows/android.yml/badge.svg)](https://github.com/vmd1/gossip/actions/workflows/android.yml)

Mac ↔ Android continuity: make your Mac, phone and tablet behave like one system.
Open source under the [Apache 2.0 license](LICENSE) — issues and PRs welcome.

## What it does

- **Universal Control** — push the Mac's cursor off a screen edge and keep going on your phone or tablet, with the Mac's mouse and keyboard
- **Screen mirroring** — mirror and control an Android screen from the Mac, with audio
- **Notification mirroring** — see phone notifications on the Mac, reply inline, dismiss in sync
- **Clipboard sync** — copy on one device, paste on another (text and images)
- **Do Not Disturb / Focus sync** — turn it on in one place, it follows everywhere
- **Media remote** — see what's playing and control playback on any device
- **Instant Hotspot** — turn on your phone's hotspot from the Mac and join it automatically
- **Lock on leave** — lock a Mac or tablet when your phone walks out of Bluetooth range
- **Find my device** — make a paired device ring at full volume
- **Battery sync** — see every device's battery, with low-battery alerts
- **Multi-device trust** — pair two devices once and every device they already trust learns about the new one

Each feature has its own per-device switch in Settings. The full list, mapped against Apple Continuity, is in [ROADMAP.md](ROADMAP.md).

## Requirements

- **Mac:** macOS 14 or newer; the prebuilt app is Apple Silicon only (Intel: building from source is untested)
- **Android:** Android 10 or newer
- **Network:** both devices on the same local network (no account, no cloud — see the [FAQ](docs/faq.md))
- **Shizuku (heavily recommended):** the app works without it, but screen mirroring, Universal Control, Instant Hotspot on Android 16+ and background clipboard reading all need it — see [Setting up Shizuku](docs/setup-shizuku.md)

## Quick start

- **Install the Mac app**
  - download `Gossip-Mac-AppleSilicon.zip` from the [latest release](https://github.com/vmd1/gossip/releases/latest), unzip it and move `Gossip.app` to `/Applications`
  - the first launch is blocked by Gatekeeper (the app is not notarized): open **System Settings → Privacy & Security** and choose **Open Anyway**
- **Install the Android app**
  - download `Gossip-Android-universal.apk` from the same release and install it
  - allow "install unknown apps" for the app you opened it with
- **Pair them**
  - Mac: menu bar icon → **Pair New Device…** shows a QR code
  - Android: **Pair New Device** (or **Scan a QR Code** during setup), then confirm on both screens
- **Set up Shizuku** on the Android device (heavily recommended) — [Setting up Shizuku](docs/setup-shizuku.md)
- **Grant permissions** on each device as prompted — each one unlocks one feature and all are skippable

The step-by-step version, with every permission explained, is in [Getting started](docs/getting-started.md).

## Guides

- [Getting started](docs/getting-started.md) — install, first run, permissions, pairing, optional setup
- [Setting up Shizuku](docs/setup-shizuku.md) — what it is, which features need it, how to start it
- [Universal Control](docs/universal-control.md) — set up, shortcuts, limits
- [FAQ](docs/faq.md) — common questions
- [Troubleshooting](docs/troubleshooting.md) — fixes for the usual problems
- [Building and signing](docs/building-and-signing.md) — build from source, tests, signing, releases

## For contributors

- **Layout**
  - Mac app: Swift, in `mac/Gossip`
  - Android app: Kotlin, in `android/app/src/main/kotlin/dev/vmd1/gossip`
  - the two share no code or compiler — [`schema/message-types.md`](schema/message-types.md) is the single source of truth keeping them in sync
- **Technical docs**
  - [`docs/architecture.md`](docs/architecture.md) — how the two apps fit together
  - [`docs/wire-protocol.md`](docs/wire-protocol.md) — byte-level framing over the socket
  - [`schema/message-types.md`](schema/message-types.md) — the message type registry
  - [`docs/adr/`](docs/adr) — architecture decision records
- **Build and test:** see [Building and signing](docs/building-and-signing.md)
