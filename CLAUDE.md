# Connect

Mac ↔ Android continuity app. Mac app is Swift (`mac/Connect`), Android app is Kotlin (`android/app/src/main/kotlin/com/connect`). No shared compiler/types between them — the wire protocol is the only contract.

## Wire protocol changes

`schema/message-types.md` is the single source of truth for every envelope `type`. Whenever a change touches what a message type carries, when it's sent, or how it's handled (new fields, new triggers, new auto-reconciliation/dedupe behavior, a type that starts actually being sent where it previously wasn't, etc.), update that file's table in the same change — not as a follow-up. A type or behavior that isn't reflected there should be treated as not really shipped, since it's the only thing keeping the two codebases in sync.

## Reconcile anything that can drift

Any message type whose delivery isn't guaranteed (sent while transiently disconnected, dropped by any other race) must have a self-healing reconciliation path, not just a one-shot send-on-change — the same pattern `dnd.update` (`isInitialSync` on every fresh connect + 60s periodic resync), `trust.roster_update` (full roster on every fresh connect + 5min periodic resync), and `lock_on_leave.config` (resend actual intent on every fresh connect + 60s periodic resync) all already use. A fire-and-forget send with no resync is a silent, permanent desync waiting to happen the first time it races a disconnect — this has already caused a real bug once (`lock_on_leave.config`; see `schema/message-types.md`) and should be treated as a design defect, not an acceptable gap, in anything new. When adding a message type that configures persistent state on the recipient (as opposed to a one-time event/trigger), build the resync in from the start rather than waiting for it to "prove it matters in practice."
