import Foundation
import Network

/// Periodic real internet/WAN reachability probe, distinct from the mesh's own
/// `connectionState`/heartbeat machinery (which only tells you whether a mesh *peer* is
/// reachable, not whether this Mac has a working internet path at all) — see
/// `docs/ble-hotspot-protocol.md`'s "Not yet built" section for the original design intent
/// this implements. Mirrors Android's `WanReachabilityMonitor`.
///
/// Probes a raw TCP connect to `1.1.1.1:443` (Cloudflare's resolver — a fixed IP, not a
/// hostname, so this never depends on DNS working) via `NWConnection` rather than ICMP
/// ping, which needs a raw socket entitlement this app doesn't have.
///
/// Fires `wentOffline` **once** per offline episode (edge-triggered, mirroring
/// `LockOnLeaveManager`'s "once per transition, not every tick" convention) after both:
/// - `offlineThreshold` (1 minute) have elapsed since the last successful probe — not
///   since the first failed probe, which only coincides with the last-good time when
///   probes are frequent and never false-negative; and
/// - at least `minConsecutiveFailures` probes have failed in a row, so a single dropped
///   probe (packet loss, a momentary Wi-Fi blip) can't trip this on its own.
final class WanReachabilityMonitor {
    static let probeHost = "1.1.1.1"
    static let probePort: UInt16 = 443
    static let probeTimeout: TimeInterval = 5
    static let probeInterval: TimeInterval = 20
    static let offlineThreshold: TimeInterval = 60
    static let minConsecutiveFailures = 3

    /// No-payload signal, fired on the main queue — matches every other Combine-ish
    /// callback in this codebase (`HotspotGattClient.requestToggle`'s completion, etc).
    var onWentOffline: (() -> Void)?

    private var lastGoodAt = Date()
    private var consecutiveFailures = 0
    private var hasFiredForCurrentEpisode = false
    private var timer: Timer?
    private let queue = DispatchQueue(label: "dev.vmd1.gossip.wanreachabilitymonitor")

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.probeInterval, repeats: true) { [weak self] _ in
            self?.probeOnce()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        probeOnce()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func probeOnce() {
        let connection = NWConnection(
            host: NWEndpoint.Host(Self.probeHost),
            port: NWEndpoint.Port(rawValue: Self.probePort)!,
            using: .tcp
        )
        var settled = false
        let settle: (Bool) -> Void = { [weak self] reachable in
            guard !settled else { return }
            settled = true
            connection.cancel()
            self?.handleProbeResult(reachable: reachable)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                settle(true)
            case .failed, .cancelled:
                settle(false)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.probeTimeout) {
            settle(false)
        }
    }

    private func handleProbeResult(reachable: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let now = Date()
            if reachable {
                self.lastGoodAt = now
                self.consecutiveFailures = 0
                self.hasFiredForCurrentEpisode = false
            } else {
                self.consecutiveFailures += 1
                let offlineDuration = now.timeIntervalSince(self.lastGoodAt)
                if !self.hasFiredForCurrentEpisode,
                   self.consecutiveFailures >= Self.minConsecutiveFailures,
                   offlineDuration >= Self.offlineThreshold {
                    self.hasFiredForCurrentEpisode = true
                    self.onWentOffline?()
                }
            }
        }
    }
}
