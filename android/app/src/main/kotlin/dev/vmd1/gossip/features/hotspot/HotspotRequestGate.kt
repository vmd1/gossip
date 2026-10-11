package dev.vmd1.gossip.features.hotspot

import uniffi.gossip_ffi.HotspotRequestGate as CoreGate

/**
 * Admission control for the BLE GATT channel, which any nearby BLE device can write to: a per-address rate limit (checked
 * before any crypto) and a bounded seen-nonce set (checked after the signature verifies) that stops a captured, still-fresh
 * request being replayed. The logic is the core's (`desktop/core/src/features/hotspot_gatt.rs`).
 */
class HotspotRequestGate(private val now: () -> Long = System::currentTimeMillis) {
    private val core = CoreGate()

    /** True if [address] is still under its request budget; counts this attempt. */
    fun allowRate(address: String): Boolean = core.allowRate(address, now())

    /** True the first time [nonce] is seen, false for a replay. */
    fun firstUse(nonce: String): Boolean = core.firstUse(nonce)
}
