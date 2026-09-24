# BLE proximity protocol

Wire-level contract for `BLEProximityMonitor` (Mac: `mac/Connect/Features/Proximity/BLEProximityMonitor.swift`;
Android: `android/app/src/main/kotlin/com/connect/features/proximity/BLEProximityMonitor.kt`). This is
**not** an `Envelope`-shaped message — see `docs/adr/0002-device-group-addressing.md` — because it
happens entirely at the BLE advertisement/scan level, with no connection and no Noise session. It's
documented here rather than in `schema/message-types.md` for that reason, per this repo's `CLAUDE.md`
convention that any wire-level contract between the two codebases needs one documented source of truth.

## Roles

- **Android phones**: BLE peripheral only — advertise, never scan.
- **Mac, Android tablets**: BLE central only — scan, never advertise.

This is deliberately not symmetric today (matching the ask: "hotspot from available android-phones...
nearby, detected by Mac and android-tablet"), but `BLEProximityMonitor` is built generically over
`DeviceType` on both platforms so a future device type (e.g. a WearOS watch) can take on either role
without a redesign.

## Advertisement payload

A standard **legacy** BLE advertisement (no extended-advertising API needed) carrying a single
manufacturer-specific-data AD structure — there's no service-UUID AD structure, because a 128-bit
service UUID (18 bytes) plus this manufacturer data wouldn't fit in the legacy 31-byte payload budget
alongside the mandatory 3-byte flags AD structure the platform adds automatically:

- **Company ID**: `0xFFFF` (the Bluetooth SIG's reserved "for testing" ID — acceptable here since
  Connect is a personal project, not a shipped product requiring a registered company ID).
- **Bytes 0–1 of the manufacturer-specific data**: a fixed 2-byte magic, `0x43 0x6E` (ASCII "Cn"),
  distinguishing Connect's advertisements from other devices/apps that also happen to use the `0xFFFF`
  test company ID.
- **Bytes 2–9**: the **first 8 bytes of SHA-256 of the device's raw X25519 static public key** — i.e.
  the exact same fingerprint already computed by `IdentityKeyStore.publicKeyFingerprint` (Mac) /
  `IdentityKeyStore.publicKeyFingerprint()` (Android) for QR pairing and mDNS TXT records, just kept as
  raw bytes here instead of base64.

Total AD structure: 1 (length) + 1 (type 0xFF) + 2 (company ID) + 2 (magic) + 8 (fingerprint) = 14 bytes,
comfortably under the legacy budget.

A scanning device recomputes this same 8-byte fingerprint for each row in its own `TrustedDevices` table
(hashing that row's already-stored `publicKeyBase64`/`publicKey`) and matches it against what it observes
over BLE — no new pairing step, no new field on `TrustedDevice`. Scanning filters on the manufacturer ID
+ magic prefix (Android: `ScanFilter.setManufacturerData` with a mask covering only those bytes; Mac:
scans without a service-UUID filter and checks the magic prefix itself once `CBAdvertisementDataManufacturerDataKey`
is read — CoreBluetooth's central role isn't subject to iOS's background-scanning service-UUID
requirement, so this is fine for a plain macOS app).

## Confirmed proximity, not a single reading

Per-`deviceId` state, reset whenever it stops being observed:

- **Enter range**: 2 consecutive advertisements at RSSI ≥ **−75 dBm**.
- **Leave range**: 6 seconds elapse with no advertisement *at or above* **−75 dBm** — a weak
  advertisement below the floor does **not** reset this timer, only one that clears the RSSI floor
  does. Confirmed live this distinction matters: an earlier version reset the timer on any reception
  at all regardless of strength, which meant a device sitting right at the boundary — still audible,
  just weak — could advertise forever without ever being declared "gone," since something was always
  arriving even as the signal degraded. Weak-but-present and fully-absent now count the same way.

This number moved twice during live testing: an initial conservative 15s was tightened to 3s for
latency, but 3s turned out to be short enough that a real, transient signal gap (not an actual
departure) tripped it as a false positive on real hardware — confirmed live: the Mac locked itself
within ~15 seconds of a fresh app launch while the phone hadn't moved. 6s is the current balance.
At the advertise interval both platforms use (`ADVERTISE_MODE_LOW_LATENCY`/`allowDuplicates: true`,
roughly one advertisement every ~100ms while both ends are foregrounded), 6 seconds of total silence
is still on the order of 60 consecutive missed advertisements, not a hair-trigger. Revisit if real
background/Doze-throttled advertise intervals (slower than foreground) turn out to make even this
trigger-happy in practice — this number assumes the foreground-like advertise rate holds.

These thresholds are a starting point, not a final tuning — see the "verify empirically" note in
`docs/architecture.md` and this feature's handoff. Expect to adjust the RSSI floor and timeout further
once tested against real walking-away-with-the-phone behavior over longer, non-benchtop sessions.

## What this primitive does *not* do

It only ever answers "is trusted device X currently within confirmed BLE range." It carries no message
traffic of its own. Features built on it decide what "in range" / "left range" *means*:

- Lock-on-leave sends its lock command over the existing Wi-Fi mesh `Envelope` transport (see
  `schema/message-types.md`), because both devices are expected to share a network for that use case.
- Instant Hotspot's `hotspot.toggle_request`/`hotspot.status` exchange cannot make that assumption (the
  whole point is reaching a phone with no shared Wi-Fi) and travels over a separate BLE GATT channel —
  documented separately once that channel is built.
