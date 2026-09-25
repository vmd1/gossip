# Gossip

Mac ↔ Android continuity app (formerly "Connect"). Mac app is Swift (`mac/Gossip`), Android app is Kotlin (`android/app/src/main/kotlin/dev/vmd1/gossip`). No shared compiler/types between them — the wire protocol is the only contract.

## Wire protocol changes

`schema/message-types.md` is the single source of truth for every envelope `type`. Whenever a change touches what a message type carries, when it's sent, or how it's handled (new fields, new triggers, new auto-reconciliation/dedupe behavior, a type that starts actually being sent where it previously wasn't, etc.), update that file's table in the same change — not as a follow-up. A type or behavior that isn't reflected there should be treated as not really shipped, since it's the only thing keeping the two codebases in sync.

## Reconcile anything that can drift

Any message type whose delivery isn't guaranteed (sent while transiently disconnected, dropped by any other race) must have a self-healing reconciliation path, not just a one-shot send-on-change — the same pattern `dnd.update` (`isInitialSync` on every fresh connect + 60s periodic resync), `trust.roster_update` (full roster on every fresh connect + 5min periodic resync), and `lock_on_leave.config` (resend actual intent on every fresh connect + 60s periodic resync) all already use. A fire-and-forget send with no resync is a silent, permanent desync waiting to happen the first time it races a disconnect — this has already caused a real bug once (`lock_on_leave.config`; see `schema/message-types.md`) and should be treated as a design defect, not an acceptable gap, in anything new. When adding a message type that configures persistent state on the recipient (as opposed to a one-time event/trigger), build the resync in from the start rather than waiting for it to "prove it matters in practice."

## All message handlers must be idempotent

Applying the same message twice must produce the same end state as applying it once — no
duplicate side effects. This isn't optional or aspirational: the reconciliation convention above
*depends* on it (a periodic resync is only safe to fire on a timer, repeatedly, whether or not
anything actually changed, because a receiver re-applying an unchanged value is required to be a
no-op), and the mesh's multi-hop relay/de-duplication is best-effort, not a guarantee — a message
can legitimately be delivered more than once (a retry, a relay race, a dedupe-cache eviction on a
long-lived connection). A handler that isn't idempotent isn't just theoretically fragile, it's a
live bug waiting for a duplicate delivery to trigger it.

Most handlers in this codebase already are, by construction: setting a value (`dnd.set`,
`clipboard.update`, `media.nowplaying`, `screen.start`/`.stop`) is naturally idempotent — writing
the same value twice ends in the same state. OR-merges (`dnd.update`) and skip-if-already-present
upserts (`trust.roster_update`) are idempotent by design and documented as such. Revoking an
already-revoked device, cancelling an already-cancelled notification, and re-writing an unchanged
clipboard value are all no-ops.

**Known non-idempotent handlers, flagged (not yet fixed) as of this writing:**

- **`media.command` with `action: "next"`/`"previous"`** — these call
  `MediaSession.transportControls.skipToNext()`/`skipToPrevious()` directly
  (`MediaControlBridge.handleCommand`); a duplicate delivery of the same command skips twice, a
  real user-visible bug, not just a theoretical one. (`"play"`/`"pause"` are fine — idempotent by
  construction.) No dedupe/idempotency key exists for this message type today.
- **`notification.reply`** — the more serious one. The receiving side
  (`NotificationListenerImpl.handleReply`, Android; `NotificationMirrorManager`'s reply handling,
  Mac) fires the *source app's own* `PendingIntent` with the reply text, which for a real
  messaging app actually sends that reply into the real conversation. A duplicate delivery sends
  the same reply **twice to the other person** — this is a real-world side effect outside the app
  entirely, not just internal state, making it the highest-severity idempotency gap in this
  codebase. There is no per-reply idempotency key (e.g. a reply-attempt UUID checked against a
  short-lived seen-set) to make a duplicate delivery a safe no-op.

Whoever picks either of these up: the fix is a small bounded "already-handled" cache keyed by
something that uniquely identifies the *attempt* (not just the notification `id`, which is
reused across distinct replies to the same notification) — e.g. a UUID generated at send time and
carried in the payload, checked against a bounded recently-handled set before acting, mirroring
the mesh relay's own recently-seen-envelope-`id` cache (`docs/wire-protocol.md`'s "De-duplication"
section) rather than inventing a new pattern.

When adding a new message type or handler, ask directly: "if this arrives twice, does anything
bad happen?" If the answer isn't obviously no, it needs either a naturally-idempotent design
(prefer this) or an explicit dedupe key before it ships — don't assume delivery-exactly-once and
find out later.
