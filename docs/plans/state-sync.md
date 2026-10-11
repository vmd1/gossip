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

| Slot | Owner | Value | Consumer |
|---|---|---|---|
| `media.nowplaying` | Android phones | `title`, `artist`, `artBase64?`, `isPlaying`, `positionMs`, `durationMs`, `packageName`; cleared when no session | Mac `MediaControlManager` |
| `notification.active` | Android phones | `ids`: the notifications currently mirrored | Mac `NotificationMirrorManager`, Android `NotificationMirrorReceiver` (drop copies no longer listed; re-send a lost dismiss) |

## Migration

Moved: `media.nowplaying`, `notification.active` (new). Still on their own message and resync, to move one at a time: `dnd.update`,
`battery.update`, `hotspot.state_update`, `display.info`, `clipboard.update` (the text value; images stay raw frames),
`lock_on_leave.config`, `ble.beacon_key`. Each move deletes that feature's resync timer and `ReconcileDue` task in both apps. The
protocol version is not bumped for the moved slots because the slot messages are new types and the old ones were never released.
