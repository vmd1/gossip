import Foundation
import Combine
import GossipCoreKit

/// Whether a trusted phone's Instant Hotspot is currently on, as last reported over the
/// mesh (the `hotspot.state` state slot, see `schema/message-types.md`) — not a BLE-scan-derived
/// signal like `BLEProximityMonitor.isHotspotAvailable`. `ssid` is best-effort (only
/// present when the reporting phone could privilegedly read it) — the icon/UI only ever
/// needs `enabled`.
struct HotspotState {
    let enabled: Bool
    let ssid: String?
}

/// Implements the **receiving** half of the `hotspot.state` slot on Mac — Mac never provides Instant Hotspot, so there is
/// no sender-side counterpart here (unlike `HotspotStateManager.kt`'s phone-only reporting path). Tracks every trusted
/// phone's last-reported hotspot on/off state for UI (a hotspot icon next to that phone's row in `MenuBarView`),
/// distinct from, and much simpler than, the BLE GATT `hotspot.toggle_request`/`hotspot.status` exchange
/// (`docs/ble-hotspot-protocol.md`) — this is a live-state convenience signal for a phone this Mac already has a mesh
/// connection to.
///
/// Last-write-wins per sender and idempotent; the per-sender map is the core's `HotspotStates`, and the core's state sync
/// keeps the slot correct across reconnects, so nothing here resyncs.
final class HotspotStateManager: ObservableObject {
    @Published private(set) var hotspotStateBySenderId: [String: HotspotState] = [:]
    private let logic = GossipCoreKit.HotspotStates()

    init(transportManager: TransportManager) {
        transportManager.addOnStateChanged { [weak self] change in
            guard change.slot == GossipCoreKit.hotspotSlot() else { return }
            self?.handleSlot(deviceId: change.deviceId, valueJSON: change.valueJSON)
        }
    }

    /// Callable from any queue: `hotspotStateBySenderId` is `@Published` and observed by the menu-bar UI, and publishing it
    /// off the main thread makes SwiftUI rebuild the `MenuBarExtra` status item on that background thread, which AppKit
    /// aborts on (`NSStatusItem setVisible:`) — a real, recurring crash once. Always hop to main.
    func handleSlot(deviceId: String, valueJSON: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let valueJSON else {
                self.logic.forget(sender: deviceId)
                self.hotspotStateBySenderId.removeValue(forKey: deviceId)
                return
            }
            guard (try? self.logic.onUpdate(sender: deviceId, payloadJson: valueJSON)) != nil,
                  let state = self.logic.stateOf(sender: deviceId) else { return }
            self.hotspotStateBySenderId[deviceId] = HotspotState(enabled: state.enabled, ssid: state.ssid)
        }
    }
}
