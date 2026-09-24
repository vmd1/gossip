# 0004: Mesh Roster Gossip and Multi-Hop Relay

## Status

Accepted. Implements the roster-gossip and multi-hop-relay work ADR 0002 explicitly deferred — see that ADR's "Explicitly not built in v1" section.

## Context

ADR 0002 built the envelope-level addressing (`senderId`/`recipientId`/`broadcast`) and the multi-row `TrustedDevices` table needed for a real device-group mesh, but deliberately stubbed out the actual group-trust and multi-hop logic. `TransportManager` on both platforms still modeled "the connection" as a single scalar, and nothing ever read `recipientId`/`broadcast` for routing — there was only ever one peer to talk to.

The goal, now being built for real: pairing with any one existing mesh member should propagate that member's identity to every other member automatically (no pairwise re-pairing), and two devices with no direct connection to each other but a shared connection to some third device should still be able to exchange messages.

## Decisions

**Connection pooling.** Both `TransportManager`s now hold a pool of live connections keyed by `deviceId` (`peers: [String: PeerConnection]` on Mac, `ConcurrentHashMap<String, PeerConnection>` on Android) instead of a single scalar connection/session. Mac dials every discovered trusted peer it isn't already connected to (previously: only the first found, and only if not already connected to *anything*). Android's inbound accept loop already structurally supported concurrent sockets; it just needed the same per-deviceId pooling instead of clobbering shared scalar fields.

**Transitive trust: auto-trust, not a confirmation queue.** A device receiving a gossiped roster entry for a device it has never paired with directly merges it straight into its local `TrustedDevicesStore`, with no user confirmation prompt. This is safe because the gossip only ever arrives over an already-Noise-authenticated direct connection from an already-trusted device — the trust chain is real, just transitive. The alternative (a pending-approval queue for gossiped devices) was rejected: it would partially defeat "pair once, propagate everywhere," since a newly-gossiped device wouldn't actually be usable until some human, possibly not even present at that device, approved it.

**Multi-hop routing: flood-forward with a hop budget, not a routing table.** Every envelope carries a `ttl` (default 8), decremented once per relaying hop and never on origination. A device receiving an envelope that isn't addressed to it (and isn't a duplicate, tracked via a bounded recently-seen-`id` cache) forwards it to every other directly-connected peer except whichever one it arrived from. A broadcast envelope is flooded to all connected peers the same way. This was chosen over any real shortest-path/routing-table computation because a realistic Connect mesh is expected to stay small (a handful of devices) — the complexity of maintaining routing state across a churning set of intermittently-connected phones/tablets/Macs was judged not worth it for that scale. See `docs/wire-protocol.md`'s "Multi-hop relay" section for the exact algorithm both platforms implement identically.

This same flood-forward mechanism is what makes roster-gossip broadcasts (`trust.roster_update`) and `trust.revoke` reach devices with no direct connection to the sender, without any dedicated re-gossip step — a receiver just merges the payload into its own store and the underlying broadcast continues propagating on its own.

**`notification.posted`/`removed` become mesh-wide broadcasts, not single-peer-targeted.** Originally android→mac only (there was only ever one Mac to mirror to). With multiple devices in a mesh, a phone's notifications should mirror onto every other trusted device — other phones/tablets included, not just Macs. This required building an Android-side notification *receiver* (`NotificationMirrorReceiver`) to mirror a peer's notification locally, symmetric to Mac's pre-existing `NotificationMirrorManager` — Android previously only had the sending half (`NotificationListenerImpl`). Reply/dismiss stay **targeted** at the specific device that posted the original notification (looked up via a `(sourceDeviceId, id)` tracking key, not a bare `id`, since more than one Android device can now post into the mesh) — broadcasting those would misdeliver to devices that never had the original notification.

**Android gains a QR-display (responder) role.** Previously only Mac could show a pairing QR; Android could only scan one. Enabling direct Android-to-Android pairing (without needing a Mac as a trust bridge) required Android's `TransportManager` to gain the same untrusted-handshake trust gate Mac already had (`onUntrustedHandshake`) — a real pre-existing gap, tolerated only because nothing untrusted could ever dial Android's listener before this feature existed. The pairing QR payload's field names were generalized from `mac*` to `responder*` accordingly, and now carries the responder's real device name/type (previously the scanning side hardcoded `"Mac"`/`DeviceType.MAC`, since Mac was the only possible responder).

## Consequences

- Every feature manager sending mesh-relevant state (DND, clipboard, notifications, roster gossip) must now think in terms of "broadcast to the mesh" vs. "targeted at one specific device," rather than "the peer." Some of this generalization (DND's OR-merge) still uses a single running scalar rather than a genuine per-sender map — it still converges correctly (OR is commutative/associative) but can't currently report which specific device(s) contributed to the merged state. Revisit if per-device attribution is ever needed.
- No durable per-peer outbound queue/retry was added — sends remain best-effort, same as pre-mesh, just resolved across a pool of peers instead of a single one.
- `trust.revoke` doesn't yet handle the edge case of a revoked device being re-gossiped by a third device that hasn't heard about the revoke yet; the periodic roster/revoke resync bounds how long that window can last, but doesn't close it structurally.
- Confirmed working end-to-end on real hardware with three simultaneously-connected devices (a Mac and two Android devices, one phone and one tablet): connection pooling, roster-gossip auto-trust propagation, DND OR-merge, and mesh-wide notification mirroring all verified live.
