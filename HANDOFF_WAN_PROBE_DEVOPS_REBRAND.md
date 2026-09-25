# Handoff: WAN-reachability auto-hotspot, CI/release pipeline, and rebrand to Gossip

Written 2026-09-25, end of a long live-testing session covering the full Instant Hotspot manual
toggle feature (GATT channel, signed+encrypted credential exchange, mesh+BLE state reconciliation,
auto-connect on both platforms) across three real devices: this Mac, a Samsung SM-S711B phone
(`R5CWB1SSLMJ`), and a Samsung SM-T500 tablet. Read `docs/ble-hotspot-protocol.md` first — it has
the complete, current design and a full log of every bug found and fixed live this session (there
were many; several were genuinely subtle OS-level gotchas, not typos). This doc is the next phase:
four largely-independent pieces of work the user asked for at the end of that session. Tackle them
in whatever order makes sense — they don't depend on each other except where noted.

## 1. WAN-reachability probe + auto-request-hotspot

This is the last unbuilt piece of the original Instant Hotspot feature (see
`docs/ble-hotspot-protocol.md`'s "Not yet built" section) — the manual toggle (request/provide,
already fully live-verified) is done; this adds an automatic trigger on top of it.

### Requirements as given

- **Check target**: `1.1.1.1` (Cloudflare's resolver) — a periodic reachability probe, not DNS
  resolution (don't depend on DNS working, since a captive portal or partial outage can break DNS
  while ICMP/TCP to a fixed IP still tells you something, and vice versa — decide the exact probe
  mechanism below, but the target IP is fixed).
- **Trigger**: after **1 minute** of being offline (no WAN reachability), automatically request
  Instant Hotspot — same GATT `hotspot.toggle_request` flow the manual "Request Hotspot" button
  already uses, just triggered by this probe instead of a tap.
- **Granularity — two separate opt-in settings**:
  - **Per-device**: whether *this* device auto-requests hotspot at all when it goes offline.
  - **Per-phone**: for a given trusted phone, whether it's an eligible auto-request target. (A
    user might trust several phones but only want auto-request against one specific one, e.g. their
    own, not a family member's.)
  - Read that back before building — it's ambiguous whether "per-device" means "per requesting
    device" (a setting on the Mac/tablet itself) or something else; the most natural reading given
    the existing `hotspot.auto_config` design note in `docs/ble-hotspot-protocol.md`'s "Not yet
    built" section ("purely local per-pair configuration... similar to `TrustedDevice.fallbackHost`
    today") is: a global per-device on/off switch, plus a per-*trusted-phone-row* toggle (stored
    like `TrustedDevice.lockOnLeaveEnabled`/`.fallbackHost` — a field on that row, local-only, never
    sent over the wire, matching every other local per-pair setting in this codebase).

### Design notes to work from

- **Probe implementation**: `docs/ble-hotspot-protocol.md`'s original design point (from the
  feature's very first handoff) said: "real internet/WAN reachability, not just mesh-peer
  liveness — needs a small periodic connectivity probe distinct from the existing
  `connectionState`/heartbeat machinery." A raw TCP connect to `1.1.1.1:443` (or `:53`) with a short
  timeout is simplest and doesn't need any new permission on either platform; a plain ICMP ping
  needs elevated privileges on Android (not available without root) so avoid that. Keep the probe
  interval reasonable (e.g. every 15–30s) — this determines how promptly a real outage is detected,
  independent of the 1-minute trigger threshold above.
- **State machine**: needs a "last known good" timestamp per device, and a 1-minute-since-last-good
  threshold before firing — not "1 minute since the first failed probe," which is the same thing
  only if probes are frequent and don't have false negatives; a debounce (e.g. require N consecutive
  failures, not just elapsed time, to avoid one dropped probe triggering a hotspot request) is
  probably worth adding, mirroring this codebase's existing "don't be a hair-trigger" philosophy
  (see `docs/ble-proximity-protocol.md`'s BLE range-loss timeout tuning story for the exact same
  kind of reasoning already applied elsewhere).
- **Which phone to target**: once offline, the requesting device needs to pick a nearby, opted-in
  (`OnboardingPreferences.provideHotspotEnabled`), auto-request-eligible (per the per-phone setting
  above) phone from `BLEProximityMonitor.nearbyDeviceIds` (or `hotspotAvailable(deviceId)`/
  `isHotspotOn(deviceId)` for a live capability/state check) and fire the same
  `HotspotGattClient.requestToggle(enable = true)` the manual button already uses. If multiple
  eligible phones are nearby, decide a tiebreak (first found is probably fine — don't over-design
  this).
- **Reconciliation**: once the auto-request succeeds and the device is back online, does anything
  need to *stop* it (turn the hotspot back off)? Not specified by the user — ask, or default to
  "no, the manual toggle/icon still controls turning it off" unless told otherwise, since
  auto-*shutoff* has its own false-negative risk (briefly losing WAN reachability mid-flight
  shouldn't yank the hotspot out from under an active connection).
- **`hotspot.auto_config`**: already named and scoped in `docs/ble-hotspot-protocol.md` as "purely
  local per-pair configuration (a timeout duration), never sent over the wire" — the per-phone
  eligibility toggle above is exactly this, so implement it under that existing name/design intent
  rather than inventing a new concept. It does **not** need a `schema/message-types.md` entry since
  it's explicitly local-only, matching `TrustedDevice.fallbackHost`'s precedent.
- **UI**: a per-device toggle (home screen, both platforms, similar to "Provide Instant Hotspot"'s
  existing row) plus a per-phone toggle (in that phone's row settings, similar to `lockOnLeaveEnabled`'s
  existing per-pair toggle in `DeviceSettingsDialog`/`DeviceSettingsWindow`).

### Known issue found this session, worth investigating before/while building this

**Android's `WifiNetworkSpecifier`-based auto-connect (`HotspotAutoConnect.kt`) shows a system
"Connect to this network?" confirmation dialog on the tablet, instead of connecting transparently.**
Confirmed live: after a successful `hotspot.toggle_request`/auto-connect flow, the tablet surfaced
Android's own network-suggestion UI prompt rather than silently joining, unlike the Mac path
(`CWInterface.associate`), which does connect transparently once Location Services authorization is
granted. This is very likely **expected Android platform behavior**, not a bug in this codebase's
code specifically: `ConnectivityManager.requestNetwork` with a `WifiNetworkSpecifier` is documented
by Google to prompt the user for confirmation unless the requesting app is privileged/on an
allowlist — this exists so a background app can't silently pull the device onto an arbitrary
Wi-Fi network. Options for a future session to evaluate, roughly in order of how likely they are to
actually work without new privileges:
- Accept the prompt as unavoidable UX for a normal (non-system, non-privileged) app and design
  around it — e.g. the auto-request flow surfaces its own in-app heads-up ("Connecting to X's
  hotspot — tap Allow") so the system prompt doesn't feel like a random interruption.
- Check whether `WifiNetworkSuggestion` (the *other* API mentioned and deliberately rejected in
  `docs/ble-hotspot-protocol.md`'s original design point, in favor of `WifiNetworkSpecifier`)
  behaves differently for a *background-triggered* auto-request specifically — the original
  rejection reasoning ("a persistent 'offer' the system may or may not act on later" vs "an
  *immediate*, one-time connection") was written for the *manual* button case; an unattended
  auto-trigger might actually prefer a suggestion's different UX tradeoff. Worth re-litigating with
  this new use case in mind rather than assuming the original call still applies unchanged.
- Check whether Shizuku (already a dependency for the *providing* side on Android 16+) can broker
  a way around the confirmation prompt for the *requesting* side too, mirroring the privileged-call
  pattern already used elsewhere in this feature — this is speculative and unconfirmed, flagged
  here only as a research direction, not a known-working path.

Don't spend more than a bounded amount of time chasing this before falling back to the "design
around the prompt" option — it may simply be a hard platform constraint.

## 2. CI/CD: build+test on every push, GitHub Release on push to `main`

Two GitHub Actions workflows (or one workflow with two triggers), following whatever conventions
`docs/architecture.md`/existing `.github/workflows/` (check `e19b758`'s commit message — "Add
multi-device mesh support, Android QR pairing, and CI workflows" — there may already be a partial
CI setup to extend rather than replace) establish:

- **On push to any branch**: build both apps and run their test suites — `./gradlew
  :app:assembleDebug :app:testDebugUnitTest` (Android, needs a JDK — this session hit a real
  incompatibility between a very new JDK (27) and this project's Android Gradle Plugin/D8 toolchain
  on this dev machine specifically; CI should pin a known-good JDK, e.g. 17, explicitly rather than
  whatever the runner image defaults to) and `xcodebuild -project Connect.xcodeproj -scheme Connect
  -destination 'platform=macOS' test` (Mac, needs a macOS runner — GitHub-hosted `macos-latest` or
  similar).
- **On push to `main`**: additionally build release artifacts and publish them to GitHub Releases.
  Needs a version-numbering scheme (not currently established anywhere in this repo as far as this
  session found — check, and if genuinely absent, the simplest starting point is probably a
  date-based or run-number-based tag rather than inventing semantic versioning for a project with no
  external users yet). The Mac app is ad-hoc signed ("Sign to Run Locally" — see `IdentityKeyStore.
  swift`'s doc comment on why, and `project.yml`'s `CODE_SIGN_STYLE: Automatic`) — a CI-built binary
  will need the same signing approach (or genuinely unsigned, distributed as a `.zip`/`.dmg` with
  Gatekeeper quarantine that the user manually clears) unless this project acquires a real Developer
  ID before this ships, which is out of scope here. The Android APK is already unsigned/debug-signed
  for local testing — decide whether release builds need a real signing key or ship debug-signed
  (fine for a personal project's own use, not fine for real distribution — flag this explicitly to
  the user rather than silently picking one).

## 3. Rebrand: Connect → Gossip

- **Android package**: `com.connect` → `dev.vmd1.gossip`. This is a real package-rename, not just a
  find/replace of the string — touches `AndroidManifest.xml`, every Kotlin file's `package`
  declaration and `import com.connect.*` statement, `build.gradle.kts`'s `applicationId`/
  `namespace`, and any hardcoded string literal that currently embeds the package name (e.g. the
  `"com.connect.DEBUG_TOGGLE_HOTSPOT"`-style broadcast action strings scattered through
  `SyncForegroundService.kt` — these are just string constants, not tied to the manifest package,
  but should be renamed for consistency: `"dev.vmd1.gossip.DEBUG_..."`). Use Android Studio's
  "Refactor > Rename Package" if working interactively, or a careful scripted
  `find … -exec sed -i ''` pass otherwise — verify with a full rebuild afterward, package renames
  are exactly the kind of change that looks done but leaves a stray reference that only breaks at
  runtime (a manifest/code mismatch, a hardcoded broadcast action string a receiver never actually
  matches anymore, etc).
- **Android app name**: the `<application android:label>` string resource, and anywhere else the
  display name "Connect" appears in Android UI strings (`strings.xml`, notification channel names,
  etc — grep for the literal string `"Connect"` across `res/` and Kotlin string literals, not just
  the manifest label).
- **Mac bundle identifier**: `com.connect.app.Connect` → something under the new `dev.vmd1.gossip`
  namespace (e.g. `dev.vmd1.gossip.Gossip` or `dev.vmd1.gossip.mac` — pick a convention and apply it
  consistently; check whether this needs to also change `PRODUCT_NAME`/target name in
  `project.yml`, which cascades into `Connect.entitlements`'s filename and
  `CODE_SIGN_ENTITLEMENTS` path, the `.app` bundle name, `NSBonjourServices`'s advertised service
  type if it embeds the bundle ID anywhere, etc — this is the same "looks like a rename, actually
  touches a dozen files" risk as the Android package rename above).
- **Mac app name**: `PRODUCT_NAME: Connect` in `project.yml`, the menu bar's `MenuBarExtra("Connect",
  ...)` in `ConnectApp.swift`, and any other user-visible "Connect" string in Mac UI code
  (`MenuBarView.swift`, onboarding windows, notification content, etc).
- **Explicitly excluded from the rename** (the user was specific about this — do not touch):
  - The **`connect://` URL scheme** (`Info.plist`'s `CFBundleURLTypes`, `AppDelegate.application(_:open:)`,
    `DNDSyncManager.handleIncomingURL`, the `connect://debug-hotspot-request` hook in
    `ConnectApp.swift`). This is a real external integration point — the user's own Shortcuts
    automations (see `docs/architecture.md`/`DNDSetupView.swift`'s onboarding instructions) are
    already configured to call `connect://dnd?state=on`/`off`, and renaming the scheme would break
    every existing Shortcut the user has already set up with no way for this codebase to know or
    migrate them.
  - The **DND Shortcuts names**: `"Connect Turn On DND"` / `"Connect Turn Off DND"` (the exact
    Shortcuts the user creates during onboarding, shelled out to via `shortcuts run "Connect Turn
    On DND"` in `DNDSyncManager.swift`/`DNDSetupView.swift`). Same reasoning — these are names of
    *user-created Shortcuts* on the user's own Mac, referenced by exact string match; renaming the
    string in code without the user also renaming their actual Shortcuts (or vice versa) breaks DND
    sync silently. If the user wants these renamed too eventually, that's a separate, explicit ask
    with its own migration step — don't fold it into a blanket "replace every Connect string" pass.
  - Likely also worth leaving alone unless told otherwise (not explicitly excluded by the user, but
    the same reasoning applies — ask before touching): anything in `schema/message-types.md`'s
    actual wire-protocol `type` strings (none currently embed "connect" as far as this session's
    work touched, but double check), and `NSBonjourServices`'s advertised service name/type if
    changing it would break discovery between an old and new build during the transition (probably
    fine to change since both apps get rebuilt together, but worth a moment's thought).
- **Everywhere else** — package/namespace declarations, class doc comments that say "Connect" in
  prose (there are hundreds across this session's own work alone — `HotspotGattProtocol.kt`'s doc
  comment literally starts "Wire-level contract for Instant Hotspot's BLE GATT control channel"
  without naming the app, but plenty of others do), `README`/`CLAUDE.md`/`docs/*.md` prose,
  `schema/message-types.md`'s own file header, memory files under
  `~/.claude/projects/.../memory/` (these are the *assistant's own persistent memory* about this
  project, not part of the repo — a future session should update relevant memories once the rebrand
  lands, so they don't keep referring to "Connect" for a project now called Gossip) — replace freely.
  Given the sheer volume, a scripted case-sensitive `Connect` → `Gossip` / `connect` → `gossip` pass
  across the repo (excluding the specific exclusions above, `.git/`, and build output directories)
  is more tractable than doing this file-by-file, but **review the diff before committing** — a
  blind replace will also hit unrelated English usages of the word "connect" (e.g. "the phone
  needs to connect to the mesh" prose, which should *not* become "the phone needs to gossip to the
  mesh"). This needs a human(-supervised) pass, not a pure `sed`.

## 4. New app icon — mesh-themed

Replace the current icon (both platforms) with something that reads as a *mesh* (nodes/edges,
several connected points) rather than the current laptop+phone glyph
(`MenuBarExtra("Connect", systemImage: "laptopcomputer.and.iphone")` on Mac is the menu bar's own
icon — separate from the actual app icon asset — decide whether that should change too, given the
app itself is fundamentally a multi-device mesh now, not just a two-device Mac↔phone pairing). Needs:
- Mac: `.icns`/asset catalog entries (`project.yml`'s resource handling, wherever the current app
  icon is sourced from — check `Connect/Resources/` for an existing `Assets.xcassets` or similar).
- Android: adaptive icon XML + PNG/vector foreground+background layers (`res/mipmap-*`/
  `res/drawable/ic_launcher*`).
- No specific visual direction was given beyond "more of a mesh icon" — this is a design judgment
  call for whoever picks this up; a simple abstract node-and-edge graphic (3-5 connected dots) in
  this project's existing color language (check `docs/design-system.md` if one exists, or the
  current icon's palette) is a reasonable default absent more specific direction from the user.

## Suggested order

1. WAN probe + auto-request (the most substantial, most load-bearing piece — finishes the feature
   this whole multi-session effort has been building toward).
2. Rebrand (touches the most files; doing it before CI/release setup means the CI config is written
   once, correctly, against the final package/app names rather than needing a follow-up edit).
3. CI/CD pipeline (benefits from #2 already being done, so release artifacts are named/signed under
   the final identity from the start).
4. Icon (lowest risk, purely additive, can genuinely be done anytime — first if you want a quick,
   low-risk warm-up before the bigger pieces, last if you'd rather batch it with other cosmetic
   changes).
