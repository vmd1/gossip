# Plan: central state synchronisation

Status: core mechanism implemented (2026-10-11), with `media.nowplaying` and `notification.active` moved onto it. The other
features still run their own resync (see "Migration" below).

## Why

`CLAUDE.md` requires that anything configuring state on another device be reconciled, not just sent once. Until now each
feature did that itself: its own message, its own on-connect send and its own 60 s timer in each of the Swift and Kotlin
apps. That is duplicated in every feature and every platform, and each copy can be wrong in its own way. Two real bugs came
from it: `media.nowplaying` said nothing when playback stopped (so a Mac could show a stale track forever) and
`notification.removed` had no resync at all (so a dismissal lost to a disconnect left a stale notification on the Mac).

## Model

Each device owns a set of **slots**: named pieces of JSON state. A feature reports state with `Core::set_state(slot, value)`
(and clears it with `None`); the core does the rest.

| Concern | How |
|---|---|
| A slot changes | broadcast `state.update` with the new version and value |
| A device connects | it is sent every slot of ours (targeted `state.update`) |
| An update was missed anyway | every 60 s each device broadcasts a `state.digest` (slot to version); a receiver that lacks a slot or holds an older version asks the owner with `state.request`, and the owner answers with `state.update` |
| A slot is cleared | the clear is a versioned value (a tombstone), so it reaches devices that were offline; "nothing playing" is state like any other |
| Ordering and duplicates | last writer wins per `(owner, slot)` by version; only a strictly newer version changes anything, so applying the same update twice, or an older one after a newer one, is a no-op (the repo's idempotency rule, by construction) |
| Who may write | only the owner: the owner is the signed sender of the message |
| A feature is turned off | its slots are neither sent nor applied on that device (the slot name is gated like a message type) |
| A device is revoked | the slots held for it are dropped and the shell is told each is gone |

Versions are the owner's clock in milliseconds, forced to grow, so a restart or a clock step back never produces a version
that loses to an older one. The digest also covers multi-hop meshes: a device that joins through a neighbour after an update
was flooded still learns it, because the owner's next digest reaches it and it requests the slot through the mesh.

Limits: slot names are 1 to 64 characters of `a-z 0-9 . _ -`; a value is at most 256 KiB; at most 64 slots per device and
per message. Large content (clipboard images, screen frames) is not state and stays in raw follow-up frames.

What is **not** state and stays a message: one-shot events (`device.ring`, `notification.reply`, `notification.dismiss`,
`media.command`), which have dedupe keys instead of a resync.

## Shell contract

- Report state with `set_state`; never resend it on a timer or on connect (the core does, and an unchanged value is a no-op,
  so calling it on every change event is fine).
- Receive other devices' slots as `StateChanged{device_id, slot, value, version}` (`value` empty means cleared or dropped);
  read the latest with `get_state(device_id, slot)`.
- Hide a device's state while the device is unreachable using the existing reachability information, not a timer of your own.

## Slots

| Slot | Scope | Owner | Value | Consumer |
|---|---|---|---|---|
| `media.nowplaying` | mesh | Android phones | `title`, `artist`, `artBase64?`, `isPlaying`, `positionMs`, `durationMs`, `packageName`; cleared when no session | Mac `MediaControlManager` |
| `notification.active` | mesh | Android phones | `ids`: the notifications currently mirrored | Mac `NotificationMirrorManager`, Android `NotificationMirrorReceiver` |
| `dnd.state` | mesh | every device | `enabled` | each device's `Dnd` (first state OR-merged, later mirrored) |
| `battery.state` | mesh | devices with a battery | `level`, `isCharging` | device lists and the low-battery alert |
| `hotspot.state` | mesh | Android phones | `enabled`, `ssid?` | hotspot icon / "Request Hotspot" |
| `control.display` | mesh | devices with a display | `width`, `height`, `rotation` | Mac Universal Control layout |
| `lock_on_leave.config` | mesh | Android phones | `armedFor`: computer ids | the computers' per-phone `lockOnLeaveEnabled` |
| `clipboard.text` | mesh | every device | `text`, `sourceDeviceId` | clipboard writers (images stay `clipboard.update` messages) |
| `direct.ble.beacon_key` | **direct only** | every device | `key` | trust row `beaconKey` |

A slot name starting with `direct.` is shared only with directly connected devices: its updates, digests and answers are
targeted with `ttl: 0`, the digest for it is sent to each neighbour separately, and a receiver ignores a copy that did not
arrive straight from its owner. It is for secrets (the BLE beacon key) that must not reach a device two hops away.

## Migration

Done: every feature that kept resendable state. `reconcile.rs` no longer lists any feature task; the apps no longer run a
resync timer or an on-connect resend for DND, battery, hotspot state, display size, clipboard text, now-playing, active
notifications, lock-on-leave or the beacon key. The only `ReconcileDue` left is the trust roster (300 s), and `mesh.topic`
and `state.digest` are handled inside the engine. Because none of the replaced messages had been released, no
compatibility path was kept: `dnd.update`, `battery.update`, `hotspot.state_update`, `display.info`, `lock_on_leave.config`,
`ble.beacon_key`, `media.nowplaying` and text `clipboard.update` are gone from the wire.
