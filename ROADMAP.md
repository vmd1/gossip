# Roadmap

What Gossip is working on, roughly in order. What already ships is described in the [README](README.md) and `schema/message-types.md`.

## Next

Most of the previous list shipped in 2.5 (locked-phone protection, login-code copy, richer notifications, image clipboard history, screen-off mirroring, Android viewer keyboard and rotation, background reliability, `media.volume`). What is left:

1. **Hardware testing.** Multi-display on a real multi-monitor Mac, Android → Android mirroring between two real devices, screen-off mirroring on more than one OEM, and the app-window fixes (black first launch, enabling disabled apps). See `docs/hardware-testing.md`.
2. **Relay hardening.** Measure the keepalive (30 s pings now) and the battery cost of a held connection on real phones.
3. **Phone as a microphone.** Android 14 only lets a microphone foreground service start while the app is visible, so the realistic route is scrcpy's `audio_source=mic` at shell UID through Shizuku (a mic-only mode in `ScrcpyServerSession` and `ShellRelay`), then a Mac player that routes to a chosen output device. Appearing as a real input device on the Mac needs an audio driver.
4. **Homebrew cask.** The `vmd1/homebrew-apps` tap is live and the cask installs 2.5; the `HOMEBREW_TAP_TOKEN` secret still has to be added so releases update it. The official Homebrew cask repo needs a notarized app, so it depends on Mac release signing (see Later).
5. **Windows app (beta).** WinUI 3 tray app over the Rust core: device list, pairing by code, clipboard, notifications with inline reply, battery and find-my-device, on the local network. Needs `windows` added to `deviceType` (a wire break, so 3.0), a C# binding to the core, and Windows CI. Linux (GTK4) follows. Plan in `docs/plans/desktop-clients.md`.
6. **Messages: RCS.** The Google Messages bridge on the phone (after a spike on account risk and session lifetime), then an Android Messages UI.
7. **File transfer** (AirDrop-style). Tried and removed before; NearDrop covers it for now.
8. **Continuity Camera:** the phone as a Mac webcam.
9. **Messages on every device.** SMS and RCS read and sent from any computer, not just the Mac. Builds on the RCS item and needs more than one computer client, so it follows the Windows beta.

## Later

- **Mac release signing.** A stable team identity so updates stop asking for the Keychain password.
- **Third-party app integration:** a local, off-by-default API so other Mac apps (such as the Droppy notch shelf in #111) can show notifications, reply, and control media, with the user approving each client. Comes after the richer notification data, and needs a design decision between a Droppy-specific client and a generic approval flow.
- **Unlock the phone from the Mac** during screen-off mirroring. Typing a credential from another device is a security risk, so it needs its own design and review.
- **Sidecar,** Mac → Android tablet first (needs a spike on the private `CGVirtualDisplay` API).
- **Auto Unlock:** unlock the Mac from a nearby trusted phone. Needs a dedicated security review first.
- **iMessage on Android** through OpenBubbles' method (rustpush), after a risk spike.
- **Computer ↔ computer:** Mac ↔ Mac first, to settle the protocol before other desktops.
- **Chrome extension,** and **send tab to phone** on top of it.
- **Phone call relay:** call signalling is easy, real call audio over Bluetooth HFP is hard and not possible on the Mac.

## Not planned

- Handoff, Continuity Markup and Sketch, Keychain handoff, Apple Watch features.
- Files and styled text in the clipboard: text and PNG is the scope.
- Automatic hotspot on connection loss: built, then removed. Instant Hotspot is manual.
- A different off-LAN transport (Iroh): evaluated and scrapped. The relay stays.
- A Watch/WearOS Do Not Disturb source: WearOS already mirrors the phone.
