# Plan: file transfer

Status: design (2026-11-12). An AirDrop-style "send this file to that device" between Mac and Android. An earlier version (`file.offer/accept/reject/complete`, 256 KiB chunks) shipped in Wave 2 and was removed in September because it auto-accepted every offer, had no resume and no limits. This plan keeps what was right (raw follow-up frames for the bytes, SHA-256 verification) and fixes those three.

## Goals and non-goals

- Send one or more files, up to 2 GiB each, from a Mac (drag onto a device row, or "Send File…") or Android (share sheet) to a trusted device in the mesh.
- The receiver must **accept** each offer. Nothing is written to disk before that.
- Transfers survive a dropped connection and resume where they left off.
- Not goals: folders (a zip is a file), sending to several devices at once, relay (off-LAN) transfers for now (the relay is rate-limited for this; offers over the relay are refused with a reason).

## Messages

All are **targeted** (`recipientId`) and signed like every envelope. `transferId` is a UUID minted by the sender per file.

| type | direction | payload |
|---|---|---|
| `file.offer` | sender→receiver | `transferId`, `name` (sanitised on receipt), `size`, `sha256` (hex of the whole file), `chunkSize`, `mime`? |
| `file.accept` | receiver→sender | `transferId`, `next` (index of the first chunk the receiver does not have yet) |
| `file.reject` | receiver→sender | `transferId`, `reason` (`declined` \| `too_large` \| `no_space` \| `busy`) |
| `file.chunk` | sender→receiver | `transferId`, `index`, `hasRawFollowup: true` carrying the bytes (`chunkSize`, last one shorter) |
| `file.complete` | receiver→sender | `transferId`, `ok` (the whole-file hash matched), `reason`? |
| `file.cancel` | either | `transferId` |

Chunks are 1 MiB, so one frame is well under the 16 MiB raw-frame cap and a lost frame costs little.

## Idempotency and reconciliation

Every handler must be safe to run twice (CLAUDE.md), and a transfer must heal itself after any drop:

- **`file.chunk`** writes at offset `index * chunkSize` into a `.part` file. Writing the same chunk twice is the same end state. A chunk for an unknown or finished `transferId` is dropped.
- **`file.accept`** is idempotent and doubles as the resume request: the sender (re)starts sending from `next`. A duplicate accept restarts from the same `next`, so chunks already sent are sent again, harmlessly.
- **`file.offer`** for a `transferId` already known re-sends the current state (the prompt is not shown twice; an already-accepted transfer answers with `file.accept` and its `next`; a finished one answers `file.complete`).
- **`file.complete`** and **`file.cancel`** on a finished or unknown transfer are no-ops.
- **Reconcile:** the sender re-sends `file.offer` for every unfinished outgoing transfer on each fresh connection to the receiver, and every 30 s while the offer is unanswered (up to 10 minutes, then it expires). The receiver, on a fresh connection, re-sends `file.accept(next)` for every accepted-but-incomplete incoming transfer. Between those two, a drop at any point converges without user action.
- The receiver keeps a bounded (128) cache of finished `transferId`s so a late duplicate offer cannot prompt again.

## Receiver rules

- The prompt shows the sender's device name, the file name and the size. **Decline is the default** after 2 minutes.
- `name` is reduced to its last path component, stripped of control characters and leading dots, and made unique in the destination (`name (2).ext`). It never contains a separator.
- Limits: 2 GiB per file, at most 3 incoming transfers at once, refuse (`no_space`) when the destination volume lacks the size plus 100 MiB.
- Write to `<name>.part`, verify the full SHA-256, then rename. A mismatch deletes the part and replies `ok: false`.
- Mac saves to `~/Downloads`; Android saves through `MediaStore.Downloads` (no storage permission needed on API 29+).

## Raw frame handler

`TransportManager.onRawFrameReceived` is a single slot that `ClipboardSyncManager` owns on both platforms. File transfer cannot just overwrite it. First step of the implementation: make it a small dispatcher keyed by envelope type (`clipboard.update`, `file.chunk`), registered by each manager.

## Order of work

1. The raw-frame dispatcher (both apps), no behaviour change.
2. The transfer state machine in the core? No: it is per-app file and UI work with no cross-platform bytes to pin, so it stays in Swift and Kotlin, with the chunking, resume and name-sanitising logic as pure, unit-tested types that both apps mirror (`schema/file-transfer-cases.json` pins the name sanitising and the resume arithmetic, like `otp-cases.json`).
3. Android receive, then Android send (share sheet).
4. Mac receive, then Mac send (drop target and a "Send File…" button).
5. Emulator e2e: `mac/scripts` pairs the Mac with the emulator already; add a send and a receive of a 5 MiB file with a forced disconnect in the middle.
6. `schema/message-types.md` rows for all six types in the same change as the code.
