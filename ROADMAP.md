# Roadmap

What Gossip is working on, roughly in order. What already ships is described in the [README](README.md) and `schema/message-types.md`.

## Urgent

- **Locked phones should not open app windows.** Refuse `screen.start` for an app window while the keyguard is locked (`KeyguardManager.isKeyguardLocked` and `isDeviceSecure`), with a new `screen.error` reason such as `locked`. Both viewers (`ScreenMirrorController` on the Mac, `ScreenViewerSession` on Android) show "Unlock to open its apps", and the reason is added to `schema/message-types.md`. Also consider ending running app windows when the phone locks (`ACTION_SCREEN_OFF` or keyguard shown), so a window left open on the Mac doesn't stay usable; what happens to an open app window today when the phone locks hasn't been checked. A setting to keep the current behaviour is optional, but the default should be that a locked phone means no app windows.

## Next

1. **Android reliability.** Keep Gossip alive in the background (a battery-optimisation exemption prompt and Samsung's per-app sleep limits), restart the sync service after an app update, show a clear "Shizuku isn't running" state, and harden the relay (keepalive tuning, NAT idle timeout, battery cost of a held connection).
2. **2FA code autofill.** Detect one-time codes in mirrored SMS and app notifications on the phone and offer them on the Mac, without sending notification text anywhere new and without auto-pasting.
3. **Hardware testing.** Multi-display on a real multi-monitor Mac, Android → Android mirroring between two real devices, and the app-window fixes (black first launch, enabling disabled apps).
4. **Finish Android → Android mirroring.** Rotation, keyboard input and a "being mirrored" indicator on the source.
5. **Clipboard history for images,** and the phone as a microphone for the Mac.
6. **Messages: RCS.** The Google Messages bridge on the phone (after a spike on account risk and session lifetime), then an Android Messages UI.
7. **Richer notifications.** Avatars, pictures, action buttons, smart replies and live notifications (calls, progress, timers), as optional fields older peers ignore, plus a targeted `notification.action` message (deduped like `notification.reply`) and `media.volume`. From the proposal in #111.
8. **Screen-off mirroring.** Mirror the phone with its own panel truly dark, off by default and needs Shizuku, with a per-device toggle. The display-power and timeout behaviour is OEM-sensitive, so it needs testing across devices. From #112; unlocking the phone from the Mac is a separate question (see Later).
9. **Mac release signing.** A stable team identity so updates stop asking for the Keychain password.
10. **Homebrew cask.** A `vmd1/homebrew-apps` tap with a `gossip` cask (`brew install --cask vmd1/apps/gossip`) that installs the release's `Gossip-Mac.zip`, checks its SHA-256 and clears the quarantine flag, with the version and checksum updated automatically on each release. Waits for the first release that ships `Gossip-Mac.zip` (2.5). The official Homebrew cask repo needs a notarized app, so it depends on release signing above.

## Later

- **Third-party app integration:** a local, off-by-default API so other Mac apps (such as the Droppy notch shelf in #111) can show notifications, reply, and control media, with the user approving each client. Comes after the richer notification data, and needs a design decision between a Droppy-specific client and a generic approval flow.
- **Unlock the phone from the Mac** during screen-off mirroring. Typing a credential from another device is a security risk, so it needs its own design and review.
- **Sidecar,** Mac → Android tablet first (needs a spike on the private `CGVirtualDisplay` API).
- **Continuity Camera:** the phone as a Mac webcam.
- **Auto Unlock:** unlock the Mac from a nearby trusted phone. Needs a dedicated security review first.
- **iMessage on Android** through OpenBubbles' method (rustpush), after a risk spike.
- **Computer ↔ computer:** Mac ↔ Mac first, to settle the protocol before other desktops.
- **Windows app** (WinUI 3 over the Rust core), then **Linux** (GTK4).
- **Chrome extension,** and **send tab to phone** on top of it.
- **Messages on every device,** once there is more than one computer client.
- **Phone call relay:** call signalling is easy, real call audio over Bluetooth HFP is hard and not possible on the Mac.

## Not planned

- File transfer (AirDrop-style): tried and removed; NearDrop covers it.
- Handoff, Continuity Markup and Sketch, Keychain handoff, Apple Watch features.
- Files and styled text in the clipboard: text and PNG is the scope.
- Automatic hotspot on connection loss: built, then removed. Instant Hotspot is manual.
- A different off-LAN transport (Iroh): evaluated and scrapped. The relay stays.
- A Watch/WearOS Do Not Disturb source: WearOS already mirrors the phone.
