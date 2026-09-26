# Gossip

Mac ↔ Android continuity app (formerly "Connect"): notification mirroring (with inline reply),
clipboard sync, Do Not Disturb/Focus sync, media/Now Playing remote control, screen mirroring, and
multi-device mesh trust (pair once, propagate everywhere). See `CONTINUITY_FEATURES.md` for the
full feature list mapped against Apple Continuity, and `docs/architecture.md` for how the two apps
fit together.

Mac app is Swift (`mac/Gossip`), Android app is Kotlin
(`android/app/src/main/kotlin/dev/vmd1/gossip`). The two share no compiler or code — `schema/message-types.md`
is the single source of truth keeping them in sync; see `CLAUDE.md` for the convention that keeps
it that way.

## Docs

- `docs/architecture.md` — how the two apps fit together
- `docs/wire-protocol.md` — byte-level framing over the socket
- `schema/message-types.md` — the message type registry
- `docs/adr/` — architecture decision records
