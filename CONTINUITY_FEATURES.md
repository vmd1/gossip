# Apple Continuity Features vs. Gossip

Apple's Continuity umbrella covers every cross-device feature that lets iPhone, iPad, Mac, and Apple Watch behave as one system. This doc lists the known Continuity features and marks which ones Gossip (this project's Mac ↔ Android app, formerly "Connect") currently replicates, which are plausible future work, and which are uncertain (either technically infeasible on Android/Mac-without-iOS, or not clearly in scope for a Mac↔Android continuity app).

Status is based on the current state of `schema/message-types.md`, the `Features/`/`features/` source trees on both platforms, and `docs/ble-hotspot-protocol.md`/`docs/ble-proximity-protocol.md`, as of 2026-09-25.

## Legend

- ✅ **Implemented** — shipped in this repo, with a corresponding wire-protocol entry where applicable
- 🔜 **Could implement** — technically feasible on Mac + Android, not yet built, reasonably scoped
- 🗄️ **Shelved** — desirable and feasible, but complicated enough to defer as a large standalone effort
- ❓ **Unsure** — feasible but doubtful value given overlap with what's already covered elsewhere
- 🚫 **Not applicable** — infeasible, redundant with an existing non-Gossip solution, or depends on Apple-ecosystem infrastructure with no Android equivalent

## Implemented ✅

| Feature | Apple's version | Gossip equivalent |
|---|---|---|
| Notification mirroring | Notification forwarding to Mac (via iPhone) | `notification.posted`/`.removed`/`.reply`/`.dismiss` — full mirror + inline reply + dismiss sync, mesh-broadcast. See [Notifications (mac)](mac/Gossip/Features/Notifications) / [notifications (android)](android/app/src/main/kotlin/dev/vmd1/gossip/features/notifications) |
| Media/Now Playing remote | Now Playing widget & remote control | `media.nowplaying`/`media.command` — playback state, album art, transport controls targeted per device. See [Media (mac)](mac/Gossip/Features/Media) / [media (android)](android/app/src/main/kotlin/dev/vmd1/gossip/features/media) |
| Do Not Disturb / Focus sync | Focus status sync across devices | `dnd.update`/`dnd.set` — bidirectional DND sync with OR-merge reconciliation and periodic resync. See [DND (mac)](mac/Gossip/Features/DND) / [dnd (android)](android/app/src/main/kotlin/dev/vmd1/gossip/features/dnd) |
| Universal Clipboard | Copy on one device, paste on another | `clipboard.update` — text and image (PNG) clipboard mirroring across the whole mesh, with echo suppression and periodic resync. See [Clipboard (mac)](mac/Gossip/Features/Clipboard) / [clipboard (android)](android/app/src/main/kotlin/dev/vmd1/gossip/features/clipboard) |
| Device pairing / trust | iCloud-account-based device trust | QR-based Noise_IK handshake pairing, `TrustedDevicesStore`, `trust.roster_update`/`trust.revoke` mesh gossip. See [Trust (mac)](mac/Gossip/Features/Trust) / [trust (android)](android/app/src/main/kotlin/dev/vmd1/gossip/features/trust) |
| iPhone Mirroring (screen mirroring) | iPhone Mirroring app (macOS 15+) | ADB-based wireless screen mirroring via bundled `adb`/`scrcpy`, QR wireless-ADB pairing. `screen.start`/`screen.stop` signaling only — video/input flows over a separate ADB channel. See [ScreenMirror (mac)](mac/Gossip/Features/ScreenMirror) |
| Instant Hotspot (use phone's cellular as Mac/tablet/other-phone internet) | Instant Hotspot | **Done.** BLE GATT request/response (`hotspot.toggle_request`/`hotspot.status`, signed with Ed25519 and AES-256-GCM-encrypted over an ECDH-derived key — see `docs/ble-hotspot-protocol.md`), privileged hotspot toggle + credential read via Shizuku (`TetherHelper.kt`/`HotspotCredentialReader.kt`), and auto-connect on the requester side (`HotspotAutoConnect`, both platforms), all live-verified end to end on real hardware (Mac ↔ Samsung SM-S711B). A live BLE-advertised on/off bit (`docs/ble-proximity-protocol.md`) plus the mesh-broadcast `hotspot.state_update` drive an availability indicator in the paired-devices UI. The manual-trigger flow is the shipped feature; the WAN-reachability-triggered auto-hotspot idea is a separate, not-currently-planned extension (see Not applicable). See [Hotspot (mac)](mac/Gossip/Features/Hotspot) / [hotspot (android)](android/app/src/main/kotlin/dev/vmd1/gossip/features/hotspot). |
| Auto Lock on device departure (proximity-based) | *(no direct Apple equivalent by name — the "leaving" counterpart of Watch/iPhone Auto Unlock's proximity signal)* | `lock_on_leave.config` — a trusted phone can arm "lock this Mac/tablet when I leave BLE range" per pairing; `BLEProximityMonitor` on the receiving side fires the actual lock (private `SACLockScreenImmediate` WindowServer call on Mac, `DevicePolicyManager.lockNow()` via device-admin on Android/tablet) on a BLE range-loss edge, with a cooldown against re-locking a just-unlocked screen. Reconciled/resent on reconnect + periodic resync, same convention as `dnd.update`. See [Proximity (mac)](mac/Gossip/Features/Proximity) / [proximity (android)](android/app/src/main/kotlin/dev/vmd1/gossip/features/proximity), `docs/ble-proximity-protocol.md`. |

## Could implement in the future 🔜

| Feature | Apple's version | Notes |
|---|---|---|
| Continuity Camera | Use iPhone as a Mac webcam/scanner | Android exposes camera2/CameraX APIs; would need a Mac-side virtual camera driver (e.g. CoreMediaIO DAL plugin) and a video-streaming transport separate from the JSON envelope framing — similar to how screen mirroring already sidesteps Noise-encrypted envelopes for bulk data. |
| Phone call relay (Mac-as-speakerphone equivalent) | Continuity for calls on Mac | Needs Android telecom APIs (`InCallService`) plus real-time audio routing over the transport — nontrivial but not blocked by any iOS-only API. |
| Auto Unlock (unlock Mac via nearby trusted device) | Apple Watch/iPhone auto-unlock | The proximity half of this is no longer hypothetical — `lock_on_leave` (above) already ships a live BLE proximity monitor, Ed25519-signed device trust, and a working Mac-side privileged-call precedent (WindowServer lock call, and separately the Shizuku-brokered privileged calls Instant Hotspot uses). What's still missing is the *unlock* action itself, which is a materially different problem than lock: there's no equivalent "just call a private API" shortcut for bypassing the login screen the way there was for suspending the session, so this still likely needs a custom PAM/AuthorizationPlugin (`sudo`-installed, storing the actual login credential) — more invasive than anything shipped so far, but the surrounding proximity/trust infrastructure it would sit on top of is now real, not speculative. |

## Shelved — desirable but complicated 🗄️

| Feature | Apple's version | Why shelved |
|---|---|---|
| Sidecar (use iPad as a second Mac display) | Sidecar | Android tablets could plausibly serve as an extended/mirrored display via a screen-sharing protocol, but this is architecturally a very different (continuous, low-latency, GPU-composited) problem than the existing scrcpy-based *phone-mirrors-onto-Mac* flow, which runs in the opposite direction. Possible, but a substantial standalone effort. |
| AirPlay (audio/video streaming to Mac) | AirPlay 2 | Android does not implement the AirPlay protocol (it's Apple-licensed); an alternative would mean building a custom streaming protocol rather than "replicating" AirPlay. Grouped with Sidecar as a large, separate streaming effort rather than a natural extension of the current notification/media/DND feature set. |
| Universal Control (share one mouse/keyboard across devices) | Universal Control | Feasible in principle (synthetic input injection via Android Accessibility Service + macOS `CGEvent` posting) but is a much larger, latency-sensitive undertaking than anything currently in this repo, and cursor hand-off between differing OS input models is nontrivial. Desirable, but complicated enough to shelve for now. |

## Unsure ❓

| Feature | Apple's version | Why uncertain |
|---|---|---|
| Watch-based notification/DND source | Apple Watch as the Focus/DND source of truth | Deliberately limited scope: WearOS already mirrors virtually everything happening on the paired Android phone onto the watch, so a Gossip-side Watch/WearOS integration would likely be redundant with what WearOS itself already surfaces rather than adding new capability. Only worth revisiting for something WearOS doesn't already replicate from the phone. |

## Not applicable 🚫

| Feature | Apple's version | Why |
|---|---|---|
| File transfer (AirDrop-style) | AirDrop | Was previously attempted and explicitly removed (see commit `998d08d`, "remove file transfer"). Not needed going forward — NearDrop already covers AirDrop-style transfer to/from Apple devices. |
| SMS/RCS relay (Text Message Forwarding equivalent) | Forward iPhone texts to Mac and reply | Not needed — Google Messages already provides web/desktop access to Android SMS/RCS. |
| Handoff (resume an in-progress task on another device) | Handoff | Not feasible: would require per-app "activity" state with no generic Android equivalent, and no practical way to hand off arbitrary third-party app state the way Apple's `NSUserActivity`-based mechanism does. |
| Continuity Markup / Sketch (annotate a doc from iPad) | Continuity Markup, Continuity Sketch | Not a useful fit — low value relative to the effort of a Mac-initiated "send this document to be annotated" flow with real-time drawing sync and per-app (Mail, Preview, etc.) integration. |
| iCloud Keychain / password AutoFill handoff | Continuity-based Keychain/password AutoFill | Pointless to build here — dedicated password managers already solve this, and taking it on would add security/trust liability well beyond the notification/media/clipboard scope of this app. |
| Continuity between Apple Watch and iPhone specifically (e.g. unlocking apps, Wallet handoff) | Watch↔iPhone Continuity | Entirely dependent on WatchOS/iOS pairing, which this project (Mac↔Android) has no path into. |
| eSIM/Continuity phone-number features tied to carrier + iCloud account | Continuity (calls/SMS via iCloud-linked Apple ID) | The call relay idea above is listed as feasible; the Apple-specific "same number across all your Apple devices via iCloud" mechanism itself is not portable, and SMS/RCS specifically is already covered by Google Messages. |
| Shared system clipboard for files/styled content | Universal Clipboard (files, styled text) | Universal Clipboard won't be expanded further — text and image (PNG) sync (already shipped, see Implemented) is the intended scope; file references and styled/RTF text are out of scope going forward. |
| Auto-hotspot on WAN-loss (timeout-triggered, no manual toggle) | Instant Hotspot's automatic fallback | Not planned — the shipped Instant Hotspot feature is manual-trigger by design; a WAN-reachability probe that auto-enables a peer's hotspot on connectivity loss is a separate, not-currently-planned extension. |
