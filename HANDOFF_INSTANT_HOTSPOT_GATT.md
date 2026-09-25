# Handoff: Instant Hotspot — GATT channel, multi-device support, credential auto-connect

Written 2026-09-25, end of a live testing session with both apps running on real hardware (Mac +
Samsung SM-S711B phone, R5CWB1SSLMJ). Read `docs/ble-hotspot-protocol.md` first — it has the
original design decisions and the privileged-call mechanism's full research trail. Read
`docs/ble-proximity-protocol.md` second — the BLE advertisement/role design this feature builds
on. This doc is the next phase: what's left, revised for two new requirements the user gave
during this session that change the shape of the remaining work.

## Current status — confirmed live again this session

The privileged-call mechanism (the hard, uncertain part) is fully working, re-verified today, not
just previously documented:

- Shizuku server was not running (needs restarting after every phone reboot — see memory
  `hotspot_write_secure_settings_insufficient.md` for the exact fork/activation details). Started
  it: `adb shell <shizuku-apk-lib-path>/lib/arm64/libshizuku.so` (run as the binary directly, not
  via `sh` — that fails with garbage errors, the file is a native ELF, not a shell script).
- `ShizukuManager` reported `CONNECTED` immediately (permission already granted from a prior
  session).
- `adb shell am broadcast -a com.connect.DEBUG_TOGGLE_HOTSPOT --ez enable true` →
  `TetherHelper.setHotspotEnabled -> SUCCESS`, `adb shell ip addr show swlan0` showed a real
  assigned IP (`10.31.228.17/24`).
- `--ez enable false` → `SUCCESS`. **Minor observed discrepancy, not chased down**: `ip addr show
  swlan0` still showed the interface UP with the same IP several seconds after the `SUCCESS`
  teardown, even though `dumpsys wifi` confirmed `num SoftApManagers:0` (the framework-level state
  is correctly stopped). Possibly just netdev/kernel-side interface-removal lag on this OEM build,
  not necessarily a real bug — worth a longer wait-and-recheck in a future session before assuming
  either way.

**What's still unbuilt** (per `docs/ble-hotspot-protocol.md`'s own "Not yet built" list, unchanged
by this session except where noted below): the BLE GATT service itself, `hotspot.toggle_request`/
`hotspot.status` payload framing over it, the `TrustedDevice` Ed25519-public-key schema extension
signed-request auth needs, the WAN-reachability probe, and UI on both platforms.

## Two new requirements from this session — read before designing anything

The user gave two pieces of scope guidance live that change the original design's shape:

### 1. Any device without internet should be able to request Instant Hotspot from any nearby opted-in phone — not just Mac

The original design (`docs/ble-hotspot-protocol.md`) was written Mac-centric: "Mac/tablets are BLE
central (GATT client)" requesting from a phone. The user's actual requirement is broader: **a Mac,
an Android tablet, or another Android phone** — any device with no internet connectivity — should
be able to request a hotspot from any nearby phone that has opted in. Two concrete consequences:

- **A phone can be a requester too**, not just a provider. Per `docs/ble-proximity-protocol.md`'s
  current role split, **Android phones are BLE peripheral only — advertise, never scan.** That
  document explicitly says the split "is deliberately not symmetric today... but
  `BLEProximityMonitor` is built generically over `DeviceType` on both platforms so a future device
  type... can take on either role without a redesign" — this is exactly that future case. A phone
  that wants to *request* hotspot from another phone needs to scan (central role) for that specific
  purpose, while still advertising (peripheral role) for its own detection by others. This is a
  real architectural extension to `BLEProximityMonitor`/`BLEProximityMonitor.kt`, not just new
  message types — **resolve this role-flexibility question first**, before writing any GATT
  request code, since the GATT client/server split assumed in the original design doc depends on
  it.
- **Any device type can be a requester in the actual GATT protocol** — the `hotspot.toggle_request`/
  `hotspot.status` messages and the credential-delivery message (see below) need a `deviceType`-
  agnostic design; don't hardcode "the central is always Mac" anywhere (the original doc's "GATT
  roles" bullet already only said Mac/tablet, which needs updating to include phone-as-requester).

### 2. A per-phone opt-in toggle gates whether that phone offers itself as a hotspot source

Not every phone should silently respond to hotspot requests. Add a persisted, user-visible toggle
— **"Provide Instant Hotspot"** — on the Android side (a phone-only setting; tablets/Mac never
provide, only request). Off by default (this flips on cellular data and battery use for a phone
that might not want to volunteer). Concrete design:

- Store it like `OnboardingPreferences`/local device settings — plain `SharedPreferences`, not
  synced over the wire (this is a local policy decision about *this* phone's own behavior, not
  mesh state).
- Gate **both** the BLE advertisement's "hotspot available" signal (see below) and the actual GATT
  server's willingness to accept a `hotspot.toggle_request` on it — a phone with the toggle off
  should not advertise the capability at all, not just refuse requests after the fact (silently
  ignoring is worse UX and also a needless BLE advertisement/battery cost).
- Where to put the toggle: `ConnectHomeScreen` (a persistent row, like the existing permission
  grant rows) is more discoverable than burying it in onboarding, since a user might enable this
  well after initial setup. Consider *also* surfacing it once during onboarding's permissions step
  for phones (`OnboardingActivity.kt`'s `PermissionsStep`) as an opt-in prompt, but the home-screen
  toggle is the one that actually needs to exist — onboarding's version would just be a shortcut
  to the same persisted flag.

**Design implication for the BLE advertisement itself**: `docs/ble-proximity-protocol.md`'s
current advertisement payload is a fixed 14 bytes (magic + 8-byte pubkey fingerprint) with no
capability bits. Adding a "hotspot available" signal needs either a spare bit somewhere in that
payload (check the legacy 31-byte budget math in that doc — there may not be room without
restructuring) or a separate, smaller advertisement/AD structure. **Do not have a requester have to
open a real GATT connection just to find out whether a nearby phone is even offering hotspot** —
that defeats the purpose of a lightweight capability check. Get this right before building the
rest; it's the one piece that's genuinely more of a protocol-design decision than an engineering
task.

## New idea from this session, worth building: credential auto-connect

The user asked whether the app could take the hotspot's SSID/password and hand them to the
requesting device so it connects automatically, instead of the user manually typing a Wi-Fi
password off their phone screen. **Yes, and it's a natural extension of this feature, not a
separate one** — do this as part of the same GATT channel work, not a follow-up:

- **Reading credentials (Android, providing phone)**: `WifiManager.getSoftApConfiguration()`
  (API 30+) returns the active `SoftApConfiguration`, whose `getSsid()`/`getPassphrase()` give the
  live credentials. This needs `NETWORK_SETTINGS`, a privileged permission — **not yet confirmed
  whether the same Shizuku/shell-UID approach `TetherHelper` already uses for the toggle also
  grants this read**. Test this early; if it doesn't, this is the actual remaining unknown in the
  whole feature (bigger than the already-solved toggle problem), not the GATT plumbing.
- **Sending credentials**: a new payload over the same BLE GATT channel as the toggle
  request/status — **not** the existing Noise-encrypted TCP mesh transport, and this matters more
  than it might look: the entire point of Instant Hotspot is a device with **no internet
  connectivity at all**, which is exactly the situation where the TCP transport can't reach it
  either. BLE doesn't require IP connectivity, which is why this feature needed its own channel in
  the first place (see `docs/ble-hotspot-protocol.md`'s own design point on this). Sign this
  payload the same way `hotspot.status` is planned to be signed (Ed25519, once the `TrustedDevice`
  schema extension lands) — credentials are more sensitive than a boolean toggle-result, so signed
  authenticity (confirming they really came from the trusted phone, not an impersonator) matters
  more here, not less.
- **Auto-connecting (Mac, requesting device)**: `CoreWLAN`'s `CWInterface.associate(toNetwork:
  password:)` joins a network programmatically. Needs Location Services authorization on macOS
  (Wi-Fi scan/association APIs are gated behind it) — a real permission ask, should be part of
  this feature's onboarding/first-use flow, not a surprise mid-feature.
- **Auto-connecting (Android tablet or phone, requesting device)**: `WifiNetworkSuggestion`
  (API 29+, no special permission) or `WifiNetworkSpecifier` (API 29+, for an immediate one-time
  connection, more appropriate here than a persistent suggestion) can join a network given
  SSID+passphrase without needing Shizuku on the *requesting* side — this is a normal public API
  for this exact "connect to a network I have credentials for" use case, unlike the
  `NETWORK_SETTINGS`-gated read needed on the *providing* side.

## Recommended build order for the next session

1. **Resolve the BLE role-flexibility question** (phone-as-requester needs to scan; currently
   can't). This blocks everything else in the multi-device requirement — don't build GATT
   messages against an assumed Mac/tablet-only requester role that then needs rework.
2. **`TrustedDevice` Ed25519 public-key schema extension** (already correctly identified as
   blocking in `docs/ble-hotspot-protocol.md` — do this regardless of the above, since signed
   requests need it either way). Update `schema/message-types.md`'s `trust.roster_update` row and
   both platforms' `TrustedDevice` model/pairing flow in the same change, per this repo's
   `CLAUDE.md` convention.
3. **"Provide Instant Hotspot" toggle** (Android, phone-only, off by default) — simple, unblocked,
   can be built in parallel with 1–2 since it's pure local UI + a persisted flag.
4. **BLE advertisement capability signal** — design the "hotspot available" bit/structure now that
   the toggle from (3) exists to gate it.
5. **GATT service + `hotspot.toggle_request`/`hotspot.status`** — the core toggle plumbing,
   generalized for any requester device type per requirement 1.
6. **Credential read** (Android providing side) — test the Shizuku `NETWORK_SETTINGS`-equivalent
   read *early* within this step, since it's the one genuinely unverified technical risk left.
7. **Credential delivery + auto-connect** (both directions, all device type combinations).
8. **WAN-reachability probe** (auto-hotspot-on-timeout trigger) — lowest priority; the manual
   toggle (1–7) is the more immediately useful half of this feature and has no dependency on it.
9. **UI on both platforms** — a request/status indicator, the credential hand-off UX (should this
   be silent/automatic once received, or show a brief "Connecting to <phone>'s hotspot..." state?
   — a UX call for that session, not decided here).

## Idempotency — design this in from the start, don't retrofit it

Per this project's `CLAUDE.md` (a new convention added the same day as this doc, after a live
session found two existing gaps — `media.command`'s skip actions and `notification.reply` — read
that section before writing any handler here): **every message handler must produce the same end
state whether it's applied once or twice.** BLE GATT in particular makes duplicate/retried
delivery more likely than the TCP mesh transport, not less — a central re-attempting a write after
an ATT timeout, a peripheral's notify firing twice across a brief disconnect/reconnect, etc. This
matters concretely for every new message type this feature introduces:

- **`hotspot.toggle_request`**: applying "enable" twice should be a no-op the second time (it
  almost certainly already is, since the underlying OS toggle is itself idempotent — "turn on an
  already-on hotspot" — but confirm this explicitly for both the Android provider side and
  whatever `TetherHelper.setHotspotEnabled` returns on a redundant call, rather than assuming).
- **`hotspot.status`**: a pure state report, naturally idempotent (last-write-wins) — no design
  changes needed, just confirm the receiver doesn't do anything more than "update the displayed
  status" on receipt.
- **Credential delivery** (whatever this ends up being named): this is the one to be careful
  with. If "receive credentials" also triggers "attempt to auto-connect" as a side effect
  (`CWInterface.associate`/`WifiNetworkSpecifier`), a duplicate delivery could trigger a second
  redundant connection attempt. Probably harmless in practice (connecting to a network you're
  already connected to is generally a no-op at the OS level), but confirm rather than assume —
  and definitely don't have it trigger any user-visible action (a toast, a UI transition) a second
  time for the same underlying event; gate that on an actual state change, not on message receipt.

## Verification expectations

Follow this session's and prior sessions' pattern: live-verify on real hardware via `adb`/logcat,
not just "builds successfully." The debug broadcast receivers
(`com.connect.DEBUG_TOGGLE_HOTSPOT`/`DEBUG_REQUEST_SHIZUKU`) in `SyncForegroundService.kt` are
still useful for isolating the toggle mechanism during this work, but the actual GATT
request/response path needs its own live test — two real devices, BLE actually exchanging the
request/status/credentials, not just the existing single-device toggle test. Remove the temporary
debug receivers once the real GATT path supersedes them (already noted as a cleanup step in
memory `hotspot_write_secure_settings_insufficient.md`).

Update `schema/message-types.md` in the same change as any new message type (`hotspot.
toggle_request`, `hotspot.status`, and whatever the credential-delivery payload is called) — these
are BLE GATT payloads, not TCP-transport envelopes, so per `docs/ble-hotspot-protocol.md`'s own
existing note they're documented in that doc rather than `schema/message-types.md`'s table, but the
same rigor applies: don't ship one without documenting its exact shape somewhere a future session
can find without re-deriving it.
