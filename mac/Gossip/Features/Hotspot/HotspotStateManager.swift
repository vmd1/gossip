import Foundation
import Combine

/// Whether a trusted phone's Instant Hotspot is currently on, as last reported over the
/// mesh (`hotspot.state_update`, see `schema/message-types.md`) — not a BLE-scan-derived
/// signal like `BLEProximityMonitor.isHotspotAvailable`. `ssid` is best-effort (only
/// present when the reporting phone could privilegedly read it) — the icon/UI only ever
/// needs `enabled`.
struct HotspotState {
    let enabled: Bool
    let ssid: String?
}

/// Implements the **receiving** half of `hotspot.state_update` on Mac — Mac never
/// provides Instant Hotspot, so there is no sender-side counterpart here (unlike
/// `HotspotStateManager.kt`'s phone-only reporting path). Tracks every trusted phone's
/// last-reported hotspot on/off state for UI (a hotspot icon next to that phone's row in
/// `MenuBarView`), distinct from, and much simpler than, the BLE GATT `hotspot.
/// toggle_request`/`hotspot.status` exchange (`docs/ble-hotspot-protocol.md`) — this is a
/// live-state convenience signal for a phone this Mac already has a mesh connection to.
///
/// Last-write-wins per sender, naturally idempotent — re-applying an unchanged reported
/// state is a no-op by construction, no dedupe needed. The Android side's own resync
/// loop (on every fresh connect + every 60s while connected) is what makes this
/// self-healing; nothing here needs its own resync logic since it never originates
/// anything.
final class HotspotStateManager: ObservableObject {
    @Published private(set) var hotspotStateBySenderId: [String: HotspotState] = [:]

    init(transportManager: TransportManager) {
        transportManager.router.register(prefix: "hotspot.state_update") { [weak self] envelope in
            self?.handleStateUpdate(envelope)
        }
    }

    /// `MessageRouter` calls handlers on the transport's network queue, and `hotspotStateBySenderId`
    /// is `@Published` and observed by the menu-bar UI — publishing it off the main thread makes
    /// SwiftUI rebuild the `MenuBarExtra` status item on that background thread, which AppKit
    /// aborts on (`NSStatusItem setVisible:`). This was a real, recurring crash: it hit when a
    /// burst of `hotspot.state_update` resyncs arrived right after a wake/reconnect. Always hop to main.
    private func handleStateUpdate(_ envelope: Envelope) {
        guard let enabled = envelope.payload["enabled"]?.boolValue else { return }
        let ssid = envelope.payload["ssid"]?.stringValue
        let sender = envelope.senderId
        DispatchQueue.main.async { [weak self] in
            self?.hotspotStateBySenderId[sender] = HotspotState(enabled: enabled, ssid: ssid)
        }
    }
}
