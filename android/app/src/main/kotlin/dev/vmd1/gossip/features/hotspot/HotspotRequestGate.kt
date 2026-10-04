package dev.vmd1.gossip.features.hotspot

/**
 * Admission control for the BLE GATT channel, which any nearby BLE device can write to:
 * a per-address rate limit (checked before any crypto) and a bounded seen-nonce set (checked after the
 * signature verifies, so garbage can't fill it) that stops a captured, still-fresh request being replayed.
 */
class HotspotRequestGate(
    private val now: () -> Long = System::currentTimeMillis,
    private val maxNonces: Int = 256,
    private val maxPerWindow: Int = 6,
    private val windowMs: Long = 60_000L,
    private val maxTrackedAddresses: Int = 64,
) {
    private val seenNonces = LinkedHashSet<String>()
    private val recentByAddress = HashMap<String, ArrayDeque<Long>>()

    /** True if [address] is still under its request budget; counts this attempt. */
    @Synchronized
    fun allowRate(address: String): Boolean {
        val t = now()
        if (recentByAddress.size >= maxTrackedAddresses && address !in recentByAddress) {
            recentByAddress.entries.removeAll { (_, q) -> q.isEmpty() || t - q.last() > windowMs }
            if (recentByAddress.size >= maxTrackedAddresses) return false
        }
        val q = recentByAddress.getOrPut(address) { ArrayDeque() }
        while (q.isNotEmpty() && t - q.first() > windowMs) q.removeFirst()
        if (q.size >= maxPerWindow) return false
        q.addLast(t)
        return true
    }

    /** True the first time [nonce] is seen, false for a replay. */
    @Synchronized
    fun firstUse(nonce: String): Boolean {
        if (!seenNonces.add(nonce)) return false
        while (seenNonces.size > maxNonces) seenNonces.remove(seenNonces.first())
        return true
    }
}
