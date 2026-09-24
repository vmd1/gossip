# Apple Continuity Features vs. Connect

Apple's Continuity umbrella covers every cross-device feature that lets iPhone, iPad, Mac, and Apple Watch behave as one system. This doc lists the known Continuity features and marks which ones Connect (this project's Mac ↔ Android app) currently replicates, which are plausible future work, and which are uncertain (either technically infeasible on Android/Mac-without-iOS, or not clearly in scope for a Mac↔Android continuity app).

Status is based on the current state of `schema/message-types.md` and the `Features/`/`features/` source trees on both platforms as of this writing.

## Legend

- ✅ **Implemented** — shipped in this repo, with a corresponding wire-protocol entry where applicable
- 🔜 **Could implement** — technically feasible on Mac + Android, not yet built
- ❓ **Unsure** — feasible but doubtful fit, or blocked by something outside this project's control (iOS-only APIs, Apple-silicon-only frameworks, closed Android/macOS APIs)
- 🚫 **Not applicable** — depends on iOS/iCloud/Apple-ecosystem infrastructure that has no Android equivalent, or was explicitly implemented then removed

## Implemented ✅

| Feature | Apple's version | Connect equivalent |
|---|---|---|
| Notification mirroring | Notification forwarding to Mac (via iPhone) | `notification.posted`/`.removed`/`.reply`/`.dismiss` — full mirror + inline reply + dismiss sync, mesh-broadcast. See [Notifications (mac)](mac/Connect/Features/Notifications) / [notifications (android)](android/app/src/main/kotlin/com/connect/features/notifications) |
| Media/Now Playing remote | Now Playing widget & remote control | `media.nowplaying`/`media.command` — playback state, album art, transport controls targeted per device. See [Media (mac)](mac/Connect/Features/Media) / [media (android)](android/app/src/main/kotlin/com/connect/features/media) |
| Do Not Disturb / Focus sync | Focus status sync across devices | `dnd.update`/`dnd.set` — bidirectional DND sync with OR-merge reconciliation and periodic resync. See [DND (mac)](mac/Connect/Features/DND) / [dnd (android)](android/app/src/main/kotlin/com/connect/features/dnd) |
| Universal Clipboard | Copy on one device, paste on another | `clipboard.update` — plain-text clipboard mirroring with echo suppression. See [Clipboard (mac)](mac/Connect/Features/Clipboard) / [clipboard (android)](android/app/src/main/kotlin/com/connect/features/clipboard) |
| Device pairing / trust | iCloud-account-based device trust | QR-based Noise_IK handshake pairing, `TrustedDevicesStore`, `trust.roster_update`/`trust.revoke` mesh gossip. See [Trust (mac)](mac/Connect/Features/Trust) / [trust (android)](android/app/src/main/kotlin/com/connect/features/trust) |
| iPhone Mirroring (screen mirroring) | iPhone Mirroring app (macOS 15+) | ADB-based wireless screen mirroring via bundled `adb`/`scrcpy`, QR wireless-ADB pairing. `screen.start`/`screen.stop` signaling only — video/input flows over a separate ADB channel. See [ScreenMirror (mac)](mac/Connect/Features/ScreenMirror) |

## Could implement in the future 🔜

| Feature | Apple's version | Notes |
|---|---|---|
| File transfer (AirDrop-style) | AirDrop | Was previously attempted and explicitly removed (see commit `998d08d`, "remove file transfer"). Re-implementable over the existing transport; would need a new `files.*` message-type family and a strategy for large binary payloads (the wire protocol currently avoids base64 blobs beyond small icons/art — see the `media.nowplaying` note in `schema/message-types.md`). |
| Continuity Camera | Use iPhone as a Mac webcam/scanner | Android exposes camera2/CameraX APIs; would need a Mac-side virtual camera driver (e.g. CoreMediaIO DAL plugin) and a video-streaming transport separate from the JSON envelope framing — similar to how screen mirroring already sidesteps Noise-encrypted envelopes for bulk data. |
| SMS/RCS relay (Text Message Forwarding equivalent) | Forward iPhone texts to Mac and reply | Android's `NotificationListenerService`/SMS provider access could mirror texts distinctly from generic notifications, enabling Mac-side send, not just reply-to-existing-thread. |
| Phone call relay (Mac-as-speakerphone equivalent) | Continuity for calls on Mac | Needs Android telecom APIs (`InCallService`) plus real-time audio routing over the transport — nontrivial but not blocked by any iOS-only API. |
| Auto Unlock (unlock Mac via nearby trusted device) | Apple Watch/iPhone auto-unlock | Android device presence is already tracked via the transport's connection state; would need a macOS unlock-authorization integration point (e.g. a PAM/AuthorizationPlugin) — more invasive than the app's current scope but not impossible. |
| Instant Hotspot (use phone's cellular as Mac internet) | Instant Hotspot | Android already exposes tethering/hotspot toggling via system APIs (with user permission); Connect could send a `hotspot.enable` command type and surface signal/battery info Apple shows in its UI. |
| Handoff (resume an in-progress task on another device) | Handoff | Would require per-app "activity" state to hand off, which has no generic Android equivalent — feasible only for specific first-party features Connect itself controls (e.g. "resume clipboard/notification context"), not arbitrary third-party apps like Apple's version. |
| Shared system clipboard for rich content (images/files) | Universal Clipboard (images, files) | Natural extension of the already-implemented plain-text `clipboard.update`; blocked mainly by the same large-binary-payload question as file transfer. |

## Unsure ❓

| Feature | Apple's version | Why uncertain |
|---|---|---|
| Sidecar (use iPad as a second Mac display) | Sidecar | Android tablets could plausibly serve as an extended/mirrored display via a screen-sharing protocol, but this is architecturally a very different (continuous, low-latency, GPU-composited) problem than the existing scrcpy-based *phone-mirrors-onto-Mac* flow, which runs in the opposite direction. Unclear if it fits this project's scope or ADB-based approach. |
| Continuity Markup / Sketch (annotate a doc from iPad) | Continuity Markup, Continuity Sketch | Needs Mac-initiated "send this document to be annotated" flow, real-time drawing sync, and a way to insert the result back into the originating app (e.g. Mail, Preview) — plausible but would need per-app integration work on the Mac side that's uncertain in value for a mostly notification/media/DND-focused app. |
| AirPlay (audio/video streaming to Mac) | AirPlay 2 | Android does not implement the AirPlay protocol (it's Apple-licensed); an alternative would mean building a custom streaming protocol rather than "replicating" AirPlay, which is really a distinct feature from device continuity. |
| Universal Control (share one mouse/keyboard across devices) | Universal Control | Feasible in principle (synthetic input injection via Android Accessibility Service + macOS `CGEvent` posting) but is a much larger, latency-sensitive undertaking than anything currently in this repo, and cursor hand-off between differing OS input models is nontrivial. |
| Watch-based notification/DND source | Apple Watch as the Focus/DND source of truth | Connect has no Watch counterpart at all — Apple Watch's role in Continuity depends on iPhone pairing infrastructure Connect doesn't have a bridge into. Could be relevant only if a WearOS counterpart app were built, which is out of scope as far as this repo currently shows. |
| iCloud Keychain / password AutoFill handoff | Continuity-based Keychain/password AutoFill | Technically buildable (a secure companion "autofill request" protocol), but overlaps heavily with password-manager territory and raises materially higher security/trust requirements than the notification/media/clipboard features already shipped — unclear if this project wants to take on that liability. |

## Not applicable 🚫

| Feature | Apple's version | Why |
|---|---|---|
| Handoff via iCloud (cross-app activity continuity tied to iCloud/NSUserActivity) | Handoff | Requires iCloud account infrastructure and `NSUserActivity` — no Android/non-Apple equivalent; the "Handoff"-flavored idea above is listed separately as a narrower, Connect-native possibility. |
| Continuity between Apple Watch and iPhone specifically (e.g. unlocking apps, Wallet handoff) | Watch↔iPhone Continuity | Entirely dependent on WatchOS/iOS pairing, which this project (Mac↔Android) has no path into. |
| eSIM/Continuity phone-number features tied to carrier + iCloud account | Continuity (calls/SMS via iCloud-linked Apple ID) | The call/SMS *relay* idea above is listed as feasible; the Apple-specific "same number across all your Apple devices via iCloud" mechanism itself is not portable. |
