import Foundation

/// Per-connection flood guard: more than `limit` frames inside one second means a peer is flooding the
/// mesh (the flood-forwarding relay would amplify it), so the connection gets dropped. Real traffic —
/// heartbeats, presence, clipboard, battery, roster gossip — is orders of magnitude below this.
/// Android has the same limiter (`InboundRateLimiter.kt`).
struct InboundRateLimiter {
    static let defaultLimitPerSecond = 400
    private let limit: Int
    private var windowStart: TimeInterval = 0
    private var count = 0

    init(limitPerSecond: Int = InboundRateLimiter.defaultLimitPerSecond) { limit = limitPerSecond }

    /// Counts one frame at `now`; false once the current one-second window is over budget.
    mutating func allow(now: TimeInterval = Date().timeIntervalSinceReferenceDate) -> Bool {
        if now - windowStart >= 1 { windowStart = now; count = 0 }
        count += 1
        return count <= limit
    }
}
