import Foundation
import Combine
import IOKit.ps
import UserNotifications
import GossipCoreKit

/// A device's battery as last reported over the mesh (the `battery.state` slot).
struct BatteryState: Equatable {
    let level: Int
    let isCharging: Bool
}

/// Battery sync on the Mac: publishes this Mac's battery level + charging state (only when it has an internal battery) as
/// the `battery.state` state slot, tracks every other device's last report for the Trusted Devices list, and raises a
/// low-battery notification when a peer drops to `lowThreshold` or below while not charging.
///
/// The decisions (change detection, last-write-wins per sender, the once-per-episode alert) are the core's `Battery`
/// (`desktop/core/src/features/battery.rs`); reconciliation is the core's state sync (`docs/plans/state-sync.md`), so
/// nothing here resends on connect or on a timer. This class only reads the power source and shows the result.
final class BatterySyncManager: ObservableObject {
    static let lowThreshold = Int(GossipCoreKit.batteryLowThreshold())
    static let rearmLevel = Int(GossipCoreKit.batteryRearmLevel())

    @Published private(set) var batteryBySenderId: [String: BatteryState] = [:]

    private weak var transportManager: TransportManager?
    private let identity: IdentityKeyStore
    private let featureSettings: FeatureSettings
    private let readBattery: () -> BatteryState?
    private let onLowBattery: (_ senderId: String, _ level: Int) -> Void
    private let logic = GossipCoreKit.Battery()
    private var runLoopSource: CFRunLoopSource?

    init(transportManager: TransportManager,
         identity: IdentityKeyStore = .shared,
         featureSettings: FeatureSettings = .shared,
         readBattery: @escaping () -> BatteryState? = BatterySyncManager.readFromSystem,
         onLowBattery: ((String, Int) -> Void)? = nil) {
        self.transportManager = transportManager
        self.identity = identity
        self.featureSettings = featureSettings
        self.readBattery = readBattery
        self.onLowBattery = onLowBattery ?? { senderId, level in
            let name = TrustedDevicesStore.shared.devices.first { $0.deviceId == senderId }?.deviceName ?? "A paired device"
            let content = UNMutableNotificationContent()
            content.title = "\(name) battery low"
            content.body = "\(name) is at \(level)% and not charging."
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "battery-low-\(senderId)", content: content, trigger: nil))
        }
        transportManager.addOnStateChanged { [weak self] change in
            guard change.slot == GossipCoreKit.batterySlot() else { return }
            self?.handleSlot(deviceId: change.deviceId, valueJSON: change.valueJSON)
        }
    }

    /// Starts reporting local changes (call once at launch) and publishes the current reading.
    func start() {
        guard runLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<BatterySyncManager>.fromOpaque(ctx).takeUnretainedValue().reportCurrentState()
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = source
        }
        reportCurrentState()
    }

    /// Publishes the current reading; the core ignores it when it is the one already published.
    func reportCurrentState() {
        guard featureSettings.isEnabled(.battery) else { return }
        let reading = readBattery().map { GossipCoreKit.BatteryState(level: UInt8(max(0, min(100, $0.level))), isCharging: $0.isCharging) }
        if case .setState(let slot, let valueJson)? = logic.report(reading: reading) {
            transportManager?.setState(slot: slot, valueJSON: valueJson)
        }
    }

    /// A peer's `battery.state` slot changed (`nil`: cleared, or the device was revoked). Main-thread only.
    func handleSlot(deviceId: String, valueJSON: String?) {
        guard let valueJSON else {
            logic.forget(sender: deviceId)
            batteryBySenderId.removeValue(forKey: deviceId)
            return
        }
        guard let effects = try? logic.onUpdate(sender: deviceId, payloadJson: valueJSON) else { return }
        for effect in effects {
            switch effect {
            case .updated(let sender):
                if let state = logic.stateOf(sender: sender) {
                    batteryBySenderId[sender] = BatteryState(level: Int(state.level), isCharging: state.isCharging)
                }
            case .lowBattery(let sender, let level):
                onLowBattery(sender, Int(level))
            case .setState:
                break
            }
        }
    }

    /// The internal battery's level/charging state, or `nil` on a Mac without one.
    static func readFromSystem() -> BatteryState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            let onAC = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let charging = (d[kIOPSIsChargingKey] as? Bool) ?? onAC
            return BatteryState(level: current * 100 / max, isCharging: charging)
        }
        return nil
    }
}
