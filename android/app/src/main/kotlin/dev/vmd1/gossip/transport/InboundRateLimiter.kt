package dev.vmd1.gossip.transport

/**
 * Per-connection flood guard: more than [limitPerSecond] frames inside one second means a peer is flooding
 * the mesh (the flood-forwarding relay would amplify it), so the connection gets dropped. Real traffic —
 * heartbeats, presence, clipboard, battery, roster gossip — is orders of magnitude below this.
 * Mac has the same limiter (`InboundRateLimiter.swift`). Not thread-safe: owned by one connection's read loop.
 */
class InboundRateLimiter(private val limitPerSecond: Int = DEFAULT_LIMIT_PER_SECOND) {
    private var windowStartMs = 0L
    private var count = 0

    /** Counts one frame at [nowMs]; false once the current one-second window is over budget. */
    fun allow(nowMs: Long = System.currentTimeMillis()): Boolean {
        if (nowMs - windowStartMs >= 1000) { windowStartMs = nowMs; count = 0 }
        count += 1
        return count <= limitPerSecond
    }

    companion object { const val DEFAULT_LIMIT_PER_SECOND = 400 }
}
