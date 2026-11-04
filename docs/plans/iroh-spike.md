# Iroh transport spike (scrapped)

**Status: scrapped (2026-10-31).** The Iroh evaluation is no longer planned; the relay stays the off-LAN transport and its launch hardening and keepalive tuning are part of the resilience pass in `ROADMAP.md`. Kept for reference only.

**Status: plan only, nothing measured yet.** The question this spike answers is whether [Iroh](https://www.iroh.computer/)
(QUIC, hole punching, a fallback relay, Ed25519 device identities) should replace the custom relay as the off-LAN
transport, shipping as 3.0 if it wins. The existing relay stays deployed until the spike decides.

## What needs real hardware and days of wall-clock time (not done)

| Measurement | How | Pass bar |
|---|---|---|
| Hole-punch success on carrier networks | Two endpoints (Mac on home Wi-Fi, phone on mobile data) dial each other 200 times across at least three carriers and two home routers; log `direct` vs `relayed` per attempt | Direct path on at least 70% of attempts, and relayed never worse than today's relay |
| Battery cost of a held connection | Phone holds one idle QUIC connection for 24 h away from home; compare `dumpsys batterystats` against the same day with the current relay socket and against no connection | No more than 1.5 percentage points of battery per day above the relay baseline |
| Carrier NAT idle timeout | Idle the connection for 30 s, 1 min, 2 min, 5 min, 10 min and see which first breaks the direct path | Pick the longest keepalive that survives; record per carrier |
| Mirroring and Universal Control off-LAN | Run `screen.*` and `control.*` over a direct Iroh stream and measure latency and frame drops | Input-to-photon within 50 ms of the LAN figure when direct; refuse when relayed, as today |

## Design points (settled on paper)

- Iroh is async, so it lives in an I/O adapter around the sans-IO core, behind the existing link interface as a second transport.
- Keep Noise_IK **inside** the Iroh stream. Iroh authenticates the endpoint, but the conformance vectors and the trust model stay the contract.
- A browser can only reach Iroh through its relay over WebSocket, which is what the Chrome extension (Phase 2 #13) would use.
- `gossip.vmd1.dev` can run as a self-hosted Iroh relay and keep serving the website.
- Replacing the transport is a wire break, so a win ships as major version 3.0.

## Spike plan

1. Add `desktop/spikes/iroh-probe` (a Rust binary, not part of the workspace build): `listen` prints an endpoint ticket, `dial <ticket>` connects, then prints path type (direct or relayed) and round-trip time every second.
2. Cross-compile the same binary for the phone with `cargo-ndk` and run it from `/data/local/tmp` over adb (the path `desktop/scripts/run-on-android.sh` already uses for core tests).
3. Run the table above, record results in this file, and decide: adopt, adopt only as a faster path beside the relay, or drop.

If the spike loses, keep the relay and revisit its launch hardening and keepalive tuning.
