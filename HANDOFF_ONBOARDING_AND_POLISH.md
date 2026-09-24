# Handoff: Onboarding flow, feature parity, security review, UX polish (in progress)

Started 2026-09-24, same day as `HANDOFF_INSTANT_HOTSPOT_SHIZUKU.md` (read that first — Instant
Hotspot's privileged-call mechanism and the clipboard Shizuku background-read are both now fully
live-verified; this doc is the next phase). This is a large, multi-session effort — **read the
"Current status" checklist below before starting work, and update it as you go.** An hourly cron
(see bottom of this doc) resumes this work automatically; each cron-triggered session should
re-read this whole file first, since it has no memory of prior runs beyond what's written here
and in `/Users/vivaan/.claude/projects/-Users-vivaan-Projects-coding-connect/memory/`.

## Ask, verbatim (2026-09-24)

The user asked for, in one message, all of the following. Nothing here is optional scope-creep —
treat each bullet as a real requirement.

1. **Fully modular hotspot-mechanism implementation** — so a future new Android version's new
   privileged-call method is easy to add without restructuring. (`TetherHelper.kt` already has
   *some* of this via its version-gated dispatch; revisit whether it's modular enough — see
   "Modularity review" below.)
2. **Onboarding flow, both platforms** — asking if the user has other devices, QR scan/show
   options, permission setup, and *testing which hotspot method actually works* on this device
   (ties into the `TetherHelper` TODO already in the code: "probe which mechanism works... rather
   than assuming from SDK level").
3. **No feature discrepancies between Mac and Android** — full parity audit.
4. **Everything documented.**
5. **Everything encrypted in transit** — security review of the wire protocol.
6. **Good UX, easy to use, graphics and animations, visually verified.**
7. **Test everything to the best of ability.**
8. **Hourly cron** that checks status and resumes work if it stopped (e.g. ran out of quota),
   continuing until this is complete. Explicit standing verbal authorization given for anything
   needing permission — the user will not be available to approve things in-app, so **anything
   that genuinely requires their in-the-moment action (tapping a permission dialog, approving an
   OAuth-style grant, something an automated safety classifier blocks) should be done as far as
   possible and then flagged here, not blocked on.**

## Current status (update this section every session)

**Last updated**: 2026-09-24, end of the session that wrote this doc.

| Phase | Status |
|---|---|
| 0. Instant Hotspot privileged call (Shizuku) | ✅ Done, live-verified — see `HANDOFF_INSTANT_HOTSPOT_SHIZUKU.md` |
| 0. Clipboard Shizuku background read | ✅ Done, live-verified — see memory `clipboard_shizuku_background_read.md` |
| 1. Modularity review of `TetherHelper` | ⬜ Not started |
| 2. Onboarding flow — Android | ⬜ Not started |
| 2. Onboarding flow — Mac | ⬜ Not started |
| 3. Mac↔Android feature-parity audit | 🟡 First pass done, deeper pass still needed |
| 4. Documentation pass | ⬜ Not started (ongoing throughout) |
| 5. Encryption-in-transit security review | ⬜ Not started |
| 6. UX/visual polish (graphics, animation) | ⬜ Not started |
| 7. Visual verification (both platforms) | ⬜ Not started |
| 8. Test pass | ⬜ Not started (ongoing throughout) |
| 9. Hourly cron | 🚫 Blocked — see note below |

## Phase 1 — Modularity review of the hotspot mechanism

`TetherHelper.setHotspotEnabled` currently branches on `Build.VERSION.SDK_INT >= ANDROID_16`.
That's one axis (OS version), which is what's known today. To make adding a *third* mechanism
(hypothetically, "Android 17 needs yet another approach") genuinely easy without restructuring:

- Consider refactoring the two current paths (`WRITE_SECURE_SETTINGS`/reflection,
  Shizuku/raw-AIDL) into a small `interface HotspotToggleMechanism { suspend fun
  isAvailable(context): Boolean; suspend fun setEnabled(context, enable): Boolean }`, with an
  ordered list of mechanisms `TetherHelper` tries in sequence (first available, or first that
  succeeds) — this is the actual generalization of the "try cheap path, fall back to Shizuku"
  logic already there, and is what the code's own `TODO(onboarding)` comment is gesturing at
  wanting eventually (probing which mechanism works, remembering the result per-device).
- This ties directly into Phase 2's onboarding "test hotspot methods" step: that UI step should
  iterate the same mechanism list, not duplicate its own probing logic.
- Keep it Kotlin-idiomatic and simple — this is 2-3 implementations, not a plugin architecture.
  Don't over-engineer for hypothetical mechanisms nobody has evidence for yet.

## Phase 2 — Onboarding flow (both platforms)

**Design intent** (infer reasonable UX from the ask — no further clarification available):
1. First-run flow, shown once (with a way to re-enter from settings later): "Do you have another
   device to connect to?" → Yes leads to the existing QR scan/show pairing flow (already built —
   `PairingViewModel.kt`/`QRScanActivity.kt` on Android, the Mac pairing UI); No skips to done.
2. Permission setup: walk through whichever permissions this device/OS actually needs — BLE
   (proximity/lock-on-leave), notification access (DND sync), device admin (lock-on-leave lock
   call), Shizuku (hotspot + background clipboard, **optional**, explain what's gained by
   granting it and that it's skippable). Reuse the existing individual "Grant X" buttons already
   in `MainActivity.kt`'s `ConnectHomeScreen` — this is about sequencing them into a guided flow
   for a first-time user, not rebuilding the grants themselves.
3. **Hotspot method testing**: per Phase 1's mechanism list, probe which one(s) actually work on
   this specific device and persist the result (a local, per-device preference — not sent over
   the wire) so `TetherHelper` doesn't have to re-probe or guess from SDK version alone at
   runtime. This is the concrete resolution of the `TODO(onboarding)` in `TetherHelper.kt`.
4. Mac side needs the equivalent: device-discovery/pairing entry point, permission walkthrough
   (Bluetooth, apparently-already-solved Accessibility-TCC-avoidance for lock-on-leave, Focus
   Shortcuts setup for DND), and whatever Mac-side capability probing applies (Mac doesn't have
   an Instant-Hotspot-style privileged-call problem, but audit for any Mac-side equivalent gap
   during Phase 3).

**Do not duplicate pairing/permission logic** — this phase is chrome around existing,
already-working mechanisms, not a rewrite of them.

## Phase 3 — Mac↔Android feature-parity audit

**First pass done (2026-09-24), shallow — a deeper behavioral pass is still needed.** Method:
confirmed every message type in `schema/message-types.md` has non-zero references on both
platforms (`grep` for the literal wire string on each side — a presence check, not a behavioral
one), then read the doc's own self-documented asymmetries (it already calls these out inline
where they exist, which is a good sign of documentation hygiene):

- **All 14 non-handshake/presence message types have both a sender and receiver implementation
  on both platforms.** No message type found with a one-sided implementation.
- **`clipboard.update`**: image sync doesn't work from Android's background even with Shizuku
  (text does) — already correctly documented as a real, intentional scope limit, not a bug.
- **`notification.dismiss`**: Mac uses a 5s poll against `getDeliveredNotifications` (macOS
  doesn't reliably fire the dismiss delegate callback for a plain banner swipe — confirmed
  directly), Android uses the standard delete-intent callback (works reliably on Android). This
  is the *same feature* implemented via the mechanism that actually works on each platform, not a
  discrepancy — correctly documented as such already.
- **`dnd.set`**: documented as unused by either app's own UI directly — only ever triggered via
  `dnd.update`'s auto-reconciliation. Not a gap, just worth knowing before assuming a UI button
  for it exists somewhere.

**What this first pass does NOT cover, and what a deeper pass should check next**: actual runtime
*behavior* parity beyond "both sides have code for it" — e.g., does the Mac-side onboarding/UI
expose every toggle Android's does and vice versa (this bleeds into Phase 2); do both platforms'
error-handling paths degrade the same way when a permission is missing; is `CONTINUITY_FEATURES.md`
itself still accurate (it predates this session's Instant Hotspot/clipboard/lock-on-leave work —
its "Could implement 🔜" row for Instant Hotspot should move to "Implemented ✅" now that the
privileged-call mechanism is live-verified, though the BLE GATT channel around it still isn't
built — word this carefully, it's not fully shipped yet). A future session should also visually
compare each platform's UI screen-by-screen (ties into Phase 7) rather than only comparing wire
protocol coverage.

## Phase 4 — Documentation pass

Once Phases 1-3 land, sweep `docs/`, `schema/message-types.md`, and `CONTINUITY_FEATURES.md` for
staleness — this project's own `CLAUDE.md` convention already requires message-types.md updates
alongside behavior changes; this phase is the catch-up/consistency pass, not a new convention.

## Phase 5 — Encryption-in-transit security review

The wire protocol is already Noise_IK-encrypted end-to-end per `docs/wire-protocol.md` (confirm
by reading it, don't assume) — this phase is a verification pass, not new crypto work:
- Confirm every message type that should be encrypted actually goes over the Noise transport
  (not, e.g., a plaintext fallback path introduced by mistake).
- Confirm the one documented plaintext exception (`handshake.hello`/`handshake.ack`, before a
  transport key exists) is legitimately unavoidable and doesn't leak anything beyond what a
  Noise_IK handshake message legitimately must.
- Confirm BLE GATT-based features (proximity, and Instant Hotspot's still-unbuilt GATT channel)
  have their own appropriate protection — BLE advertisement data is inherently public/broadcast,
  so "encrypted in transit" for BLE proximity likely means "carries nothing sensitive", not
  literal encryption; document that reasoning rather than treating it as a gap.
- Confirm `TrustedDevicesStore`/`IdentityKeyStore` use `EncryptedSharedPreferences`/Keychain
  correctly on both platforms (at-rest, not in-transit, but worth confirming while auditing).

## Phase 6 — UX/visual polish

Graphics, animations, visual consistency pass on both platforms' UI. No existing design system
docs found in this repo as of this writing — establish one (colors, spacing, motion conventions)
if none exists, rather than ad-hoc per-screen decisions. This is the least-specified part of the
ask; use judgment, but don't over-invest relative to the functional phases above.

## Phase 7 — Visual verification

Use the `run`/iOS-simulator-equivalent tooling available for this session to actually launch and
screenshot both apps' key flows after Phase 6, on real devices (this project has no iOS
component, but the Android Simulator-equivalent is real hardware over adb — screenshot via `adb
exec-out screencap`). **Note for future sessions**: the user said the phone screen will be kept
locked going forward — screenshot/UI-interaction testing on the phone specifically may not be
possible; rely on logcat-based verification there and prefer the tablet (or Mac) for any visual
check that needs an unlocked screen.

## Phase 8 — Test pass

Whatever automated tests exist (check for a test task in each Gradle module / Xcode scheme) plus
manual live verification via adb/logcat, following this session's established pattern (the
Instant Hotspot and clipboard Shizuku work were both verified live on real hardware, not just
"builds successfully").

## Phase 9 — Hourly cron for autonomous continuation

**Blocked**: attempted via `mcp__scheduled-tasks__create_scheduled_task` (the durable,
disk-persisted mechanism — `CronCreate` was deliberately not used instead, since it's explicitly
session-only/in-memory and would die with the exact quota-exhaustion failure mode this was meant
to survive). The automated safety classifier denied creating the scheduled task outright, even
with the user's explicit standing verbal authorization in this session — same class of hard gate
as the third-party-binary-download block (see memory `classifier_blocks_untrusted_binary_downloads.md`).
Retrying through another tool wasn't attempted per that gate's own instruction not to work around
it. **The user needs to set this up themselves** — either via the Claude Code app's own
scheduled-task/routine UI, or by asking a live session to create it (the block may be specific to
unattended/background creation, not to the mechanism itself — worth trying once interactively
before assuming it's a blanket ban). The full prompt this session intended to use is preserved
below so it doesn't need re-deriving:

> You're resuming work on the Connect project at /Users/vivaan/Projects/coding/connect (a
> Mac↔Android continuity app). This is a recurring hourly check-in, not a one-off task — a
> previous session was asked to work through a large, multi-phase piece of work autonomously and
> set up this scheduled task specifically so the work continues even if that session's quota ran
> out or it otherwise stopped mid-way.
>
> First: read /Users/vivaan/Projects/coding/connect/HANDOFF_ONBOARDING_AND_POLISH.md in full — it
> has the original ask verbatim, a phase-by-phase plan, and a "Current status" table you must
> check first. Also skim
> /Users/vivaan/.claude/projects/-Users-vivaan-Projects-coding-connect/memory/MEMORY.md and follow
> any links relevant to whatever phase you're resuming — this project has extensive memory files
> from past sessions documenting hard-won findings (build gotchas, confirmed-dead approaches,
> live-verified mechanisms) that you must not re-derive from scratch.
>
> If the status table shows every phase complete: do nothing further — just reply confirming
> completion, and you may let this be one of your last runs (the user can delete the scheduled
> task once confirmed done; you cannot delete it yourself, but you can note in your reply that it
> should be turned off).
>
> Otherwise: pick up the next incomplete phase and make real, concrete progress — write code,
> build it, install it on the connected devices via adb (phone serial R5CWB1SSLMJ, tablet at
> whatever wireless-adb address `adb devices -l` shows currently — it changes between sessions,
> reconnect via `adb connect <ip>:<port>` or mDNS auto-discovery if needed), and verify live
> wherever the existing session pattern in memory shows how (logcat greps, adb broadcasts to the
> temporary DEBUG_* receivers in SyncForegroundService.kt, screenshots via `adb exec-out
> screencap`). The user said the phone's screen will be kept locked going forward — avoid needing
> an unlocked phone screen; prefer the tablet or Mac for anything needing visual/UI interaction,
> and note in the handoff doc if something is only testable on the phone.
>
> Update HANDOFF_ONBOARDING_AND_POLISH.md's status table and any relevant section before you
> finish, so the next hourly run (or the user, whenever they check back) can see real progress.
> Follow this project's CLAUDE.md convention: any wire-protocol behavior change must update
> schema/message-types.md in the same change. Commit nothing to git unless explicitly instructed
> elsewhere in the handoff doc — the user reviews commits themselves.
>
> If you hit something genuinely blocked (not just effortful) — e.g. a safety classifier blocking
> a third-party download, or something needing an in-the-moment tap on a locked phone — do as much
> as possible around it, then add it to the "Things that may need to be flagged" section of the
> handoff doc rather than stalling. The user gave standing verbal authorization for anything
> needing permission within this project's scope; they will not be available to approve things
> interactively, so don't block waiting on approval you can reasonably infer from the handoff
> doc's intent.
>
> Keep this run reasonably scoped — make solid, verifiable progress on one or two phases, don't
> try to rush through everything in one shot. Quality and live verification over speed.

## Things that may need to be flagged rather than done autonomously

Per the user's explicit instruction: attempt everything possible first; only flag something here
if it's genuinely blocked (not just effortful). Known candidates going in:
- Anything requiring a fresh third-party binary install (same classifier gate hit for the
  Shizuku fork this session — see memory `classifier_blocks_untrusted_binary_downloads.md`).
- Any real permission-dialog tap on the phone specifically, now that its screen is kept locked —
  route around this by using the tablet or Mac wherever a live permission grant is genuinely
  needed for verification, and note in this doc if something can only be tested on the phone.
