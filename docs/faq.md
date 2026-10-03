# FAQ

## The basics

- **What is Gossip?**
  - a Mac ↔ Android continuity app (it was called "Connect")
  - it links a Mac with Android phones and tablets: notification mirroring, clipboard, Do Not Disturb, media control, screen mirroring, Universal Control and more
  - see the [feature list](../README.md#what-it-does) and the [roadmap](../ROADMAP.md)
- **Is it free and open source?**
  - yes, under the [Apache 2.0 license](../LICENSE); issues and pull requests are welcome
- **Which devices does it support?**
  - Mac: macOS 14 or newer (the prebuilt app is Apple Silicon only; on Intel you can try [building from source](building-and-signing.md), which is untested)
  - Android: Android 10 or newer, phones and tablets
  - there is no Windows, Linux or iOS version yet
- **Is it on the App Store or Google Play?**
  - no — install it from the [GitHub releases](https://github.com/vmd1/gossip/releases/latest), or build it yourself
- **Do I need an account?**
  - no; there is no sign-in and no server

## Privacy and security

- **Where does my data go?**
  - devices talk directly to each other over your local network; there is no cloud service and no relay in the middle
  - nothing is sent to the project's authors
- **Is the connection encrypted?**
  - yes: devices authenticate and encrypt every session with the Noise `IK` handshake (see [architecture](architecture.md))
  - pairing happens by scanning a QR code, which carries the public key of the device showing it
  - Universal Control input uses its own encrypted channel straight to the device (see the [message types](../schema/message-types.md))
- **What does "pair once, trust everywhere" mean?**
  - when you pair two devices, they share their trusted-device lists, so a third device that already trusts one of them learns about the other
  - you can remove any device with **Forget This Device…** and the removal spreads to the others
- **Can someone else on my Wi-Fi connect to my devices?**
  - only a device you paired (or one that a device you trust vouches for) is accepted; an unknown device must be confirmed by you on screen

## Installing

- **Why does macOS block the app on first launch?**
  - the Mac app is not signed with an Apple Developer ID and is not notarized (that needs a paid Apple Developer account)
  - open **System Settings → Privacy & Security** and click **Open Anyway** once (details in [Getting started](getting-started.md#1-install-the-mac-app))
- **Why does Android warn about the APK?**
  - it is a side-loaded build signed with the project's own key, not a Play Store release
  - allow "install unknown apps" for the app you opened it with
- **Does it work on an Intel Mac?**
  - the prebuilt download is Apple Silicon only; on Intel you can try building from source, but that is untested
- **Do I need to root my phone?**
  - no

## Shizuku

- **What is Shizuku and why does Gossip use it?**
  - a free app that lets other apps use Android's shell-level privileges without root
  - Gossip needs it for screen mirroring, Universal Control, Instant Hotspot on Android 16+ and background clipboard reading
  - details and setup: [Setting up Shizuku](setup-shizuku.md)
- **Can I use Gossip without it?**
  - yes; notification mirroring, Do Not Disturb sync, media control, lock on leave, find my device, battery sync, foreground clipboard sync and Instant Hotspot on Android 10–15 all work without it
- **Do I have to restart Shizuku?**
  - after every reboot of the device, unless it is rooted

## Features

- **Which features need which permissions?**
  - see [Getting started](getting-started.md); every permission is optional and unlocks one feature
- **Can I turn a feature off?**
  - yes; **Settings → Features** on each device
  - a feature that is off stops sending and receiving entirely on that device, and the other devices keep their own settings
- **Why does Do Not Disturb sync need setup on the Mac?**
  - macOS does not let apps read or change Focus directly, so Gossip uses the Shortcuts app (see [Getting started](getting-started.md#mac-do-not-disturb-sync))
- **How do I mirror a device's screen?**
  - the device needs [Shizuku running](setup-shizuku.md) and must be reachable from the Mac
  - open the device list in Gossip (or the Device Mirroring app) and click **Mirror** next to it
- **Can I control my Mac from my phone's keyboard and mouse?**
  - no; Universal Control goes Mac → Android only
- **Does it work outside my home network?**
  - not directly: devices must be on the same network (or reachable through each other)
  - for devices on another network, a **Fallback IP** (for example a Tailscale address) can be set per device in the Mac's device menu; a general off-network mode is on the [roadmap](../ROADMAP.md)

## Everyday use

- **What do the green, blue and grey device icons mean?**
  - green — a live direct connection
  - blue — reachable only through another device
  - grey — not reachable
- **Does Gossip drain my battery?**
  - Android runs it as a foreground service (with a persistent notification) so it can stay connected; background activity is light, but heavy use of screen mirroring or Universal Control costs battery like any streaming
- **How do I update?**
  - install the new release over the old one; your pairings and settings are kept
- **How do I remove Gossip?**
  - Mac: quit it from the menu bar and delete `Gossip.app`
  - Android: uninstall it as usual

## Still stuck?

- [Troubleshooting](troubleshooting.md)
- open an [issue](https://github.com/vmd1/gossip/issues) with your Mac and Android versions, what you tried, and any logs (see the troubleshooting page for how to get them)
