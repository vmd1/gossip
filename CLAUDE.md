# Connect

Mac ↔ Android continuity app. Mac app is Swift (`mac/Connect`), Android app is Kotlin (`android/app/src/main/kotlin/com/connect`). No shared compiler/types between them — the wire protocol is the only contract.

## Wire protocol changes

`schema/message-types.md` is the single source of truth for every envelope `type`. Whenever a change touches what a message type carries, when it's sent, or how it's handled (new fields, new triggers, new auto-reconciliation/dedupe behavior, a type that starts actually being sent where it previously wasn't, etc.), update that file's table in the same change — not as a follow-up. A type or behavior that isn't reflected there should be treated as not really shipped, since it's the only thing keeping the two codebases in sync.
