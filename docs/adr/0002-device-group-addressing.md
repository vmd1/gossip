# 0002: Device-Group Addressing From Day One

## Status

Accepted.

## Context

Wave 1 ships a single Mac talking to a single Android phone — nothing more. But the user's stated long-term goal for Connect is a multi-device "ecosystem": potentially several phones, tablets, and Macs all trusting each other as a group, not just one fixed pair.

If the wire envelope only ever identified messages implicitly (i.e. "the other end of this socket"), adding multi-device support later would require reworking the envelope shape, every message handler that assumes a single peer, and the trust/session model simultaneously — a protocol rewrite done under pressure once multi-device becomes a real feature request, rather than a deliberate design done once up front.

## Decision

Address every message envelope by device ID from day one:

- `senderId` — the device UUID that produced the message.
- `recipientId` — the device UUID it's addressed to, or `null` when `broadcast` is used instead.
- `broadcast` — a flag reserved for future fan-out to all trusted devices in a group.

This is true even though Wave 1's actual behavior is degenerate: there are only ever two trusted devices, so `recipientId` is always "the other one" and `broadcast` is unused. See `schema/envelope.schema.json` for the field definitions and `docs/architecture.md` for the accompanying `TrustedDevices` table design that backs device identity.

**Explicitly not built in v1:** the actual multi-device roster-gossip logic (devices learning about and trusting each other transitively as a group) is not implemented. `trust.roster_update` (see `schema/message-types.md`) is registered as a message type now, with its payload shape defined, but is a stub — nothing sends or handles it yet. It exists in the registry so the envelope-level addressing story is complete and reviewable, without pulling forward the (considerably more complex) group-trust and gossip protocol work.

## Consequences

- Every message handler on both sides must check `recipientId`/`broadcast` against its own device identity even in v1, which is trivial work now (always true) but means the check is already in place when it stops being trivial.
- The `TrustedDevices` table (device UUID → public key → metadata) is a table, not a single "paired device" field, from the first implementation — see `docs/architecture.md`.
- Multi-device support, when it ships, is expected to be primarily a roster-gossip protocol (`trust.roster_update` becoming real) plus config/UI work, not a wire-format migration.

**Superseded by:** `docs/adr/0004-mesh-roster-gossip-and-relay.md`, which implements the roster-gossip logic and multi-hop relay this ADR deferred. This ADR's own decisions (envelope addressing, the `TrustedDevices` table shape) remain in effect unchanged.
