# Getting started

Everything you need to go from nothing to a working Mac ↔ Android setup.

## Before you start

- **Mac:** macOS 14 or newer. The prebuilt app is Apple Silicon only; on an Intel Mac you can try [building from source](building-and-signing.md), which is untested
- **Android:** Android 10 or newer
- **Network:** put both devices on the same Wi-Fi or LAN
  - Gossip discovers devices over the local network (Bonjour/mDNS) and talks to them directly
  - guest networks and "client isolation" settings usually block this — see [Troubleshooting](troubleshooting.md)
- **Optional but recommended:** [set up Shizuku](setup-shizuku.md) on the Android device if you want screen mirroring or Universal Control

## 1. Install the Mac app

- download `Gossip-Mac-AppleSilicon.zip` from the [latest release](https://github.com/vmd1/gossip/releases/latest)
- unzip it and move `Gossip.app` into `/Applications` (or `~/Applications`)
- open it
  - macOS blocks the first launch because the app is not notarized (that needs a paid Apple Developer ID)
  - open **System Settings → Privacy & Security**, scroll to **Security**, and click **Open Anyway** next to the Gossip message
  - alternative: remove the quarantine flag in Terminal with `xattr -dr com.apple.quarantine /Applications/Gossip.app`
- Gossip lives in the **menu bar** — there is no Dock icon or main window
- the first time it runs from an Applications folder it also adds a small **Device Mirroring** app next to itself
  - it lets you open your device list and start mirroring from Spotlight or Launchpad
  - turn it off under Gossip's **Settings → Apps**

### Mac permissions

- macOS asks for these as features need them; every one is optional
  - **Local Network** — to find and talk to your devices
  - **Bluetooth** — to detect when your phone is nearby (Lock on leave)
  - **Location** — only so Gossip can join a phone's Instant Hotspot automatically (a macOS rule for any app that joins Wi-Fi networks)
  - **Notifications** — to show mirrored phone notifications and low-battery alerts
  - **Accessibility** and **Input Monitoring** — only for [Universal Control](universal-control.md)
- change any of them later in **System Settings → Privacy & Security**

## 2. Install the Android app

- download `Gossip-Android-universal.apk` from the same release on your phone or tablet
- install it
  - Android asks you to allow "install unknown apps" for the app you opened the file with (browser or file manager)
  - it is a side-loaded, self-signed build, not a Play Store app, so Android may warn about it
- open Gossip; the **Set up Gossip** screen walks you through the rest

### Android permissions

- the setup screen lists these; each unlocks one feature and all are skippable (grant them later under **Settings → Permissions**)
  - **Post notifications** — shows Gossip's sync notification and lets mirrored notifications from other devices display
  - **Notification mirroring** (Notification access) — mirrors this device's notifications to paired devices
  - **Do Not Disturb sync** (Do Not Disturb access) — keeps Focus/DND in sync
  - **Bluetooth** — detects nearby trusted devices
  - **Device admin** — lets a paired phone lock this device when it leaves Bluetooth range
  - **Shizuku (heavily recommended)** — screen mirroring, Universal Control and more need it; see [Setting up Shizuku](setup-shizuku.md)
- for reliable syncing, let Gossip run in the background: it keeps a foreground service running, and aggressive battery optimisation on some phones can stop it (see [Troubleshooting](troubleshooting.md))

## 3. Pair your devices

- **Mac ↔ Android**
  - on the Mac: click the menu bar icon → **Pair New Device…** to show a QR code
  - on Android: tap **Pair New Device** (or **Scan a QR Code** during setup) and scan it
  - confirm on both screens
- **Android ↔ Android**
  - on one device: tap **Show QR to Pair** (during setup: **Show My QR Code**)
  - on the other: scan it with **Pair New Device**
- pairing is encrypted and happens once per pair
- devices you already trust share their lists, so after you pair a third device with one of them, the others learn about it automatically
- remove a device any time with **Forget This Device…** in its menu

You can reopen setup later: on Android under **Settings → Devices & pairing**, on the Mac under **Settings… → Devices & setup → Run Setup Again…**.

## 4. Check the connection

- the device list shows how each device is reachable
  - **green** — a live direct connection
  - **blue** — reachable only through another device (messages still arrive, but features that need a direct link, like Universal Control, do not work)
  - **grey** — not reachable
- **Settings → Features** (on either platform) turns individual features on or off; a feature that is off stops sending and receiving entirely on that device

## 5. Optional setup

### Mac Do Not Disturb sync

- macOS does not let apps read or change Focus directly, so Gossip uses the Shortcuts app
- open Gossip's **Settings… → Devices & setup → Do Not Disturb Sync Setup…** and follow it once
  - **Reporting** (tell your phone when the Mac's Focus changes): two Shortcuts *automations* — "When Focus is turned on" and "When Focus is turned off" — each with an **Open URL** action: `connect://dnd?state=on` and `connect://dnd?state=off`; turn off **Ask Before Running** for both
  - **Control** (let your phone change the Mac's Focus): two Shortcuts named exactly `Connect Turn On DND` and `Connect Turn Off DND`, each with a **Set Focus** action (On / Off)

### Instant Hotspot

- Android 10–15: grant the secure-settings permission once from a computer (see [Setting up Shizuku](setup-shizuku.md#instant-hotspot-without-shizuku-android-1015))
- Android 16 and newer: needs Shizuku running
- on the phone, **Settings → Instant Hotspot** (or the **Test Hotspot Methods** button in setup) checks which method works on your phone

### Screen mirroring and Universal Control

- both need Shizuku running on the Android device — see [Setting up Shizuku](setup-shizuku.md)
- Universal Control also needs two Mac permissions — see [Universal Control](universal-control.md)

## Updating and uninstalling

- **update:** install the new release over the old one
  - the Mac app and the Android app both keep their data and pairings
  - Android only accepts an update signed with the same key as the installed app; if a build from another source refuses to install, uninstall first
- **uninstall Mac:** quit Gossip from the menu bar, then delete `Gossip.app` (this also removes the Device Mirroring app); its data lives in `~/Library/Application Support/Connect`
- **uninstall Android:** remove the app as usual; also remove Gossip from Shizuku's authorised apps if you want
