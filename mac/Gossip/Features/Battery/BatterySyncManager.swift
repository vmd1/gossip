import Foundation
import Combine
import IOKit.ps
import UserNotifications

/// A device's battery as last reported over the mesh (`battery.update`).
struct BatteryState: Equatable {
    let level: Int
    let isCharging: Bool
}

/// Implements `battery.update` (see `schema/message-types.md`) on the Mac: broadcasts this Mac's
/// battery level + charging state (only when it has an internal battery), tracks every other
/// device's last report for the Trusted Devices list, and raises a low-battery notification when a
/// peer drops to `lowThreshold` or below while not charging.
///
/// **Reconciled**, per this repo's `CLAUDE.md` convention: sent on every local change (power-source
/// notification), on every fresh connect and every 60s while connected (`reportInitialSyncState`,
/// driven from `ConnectApp` like the DND/clipboard resyncs). Receiving is last-write-wins per
/// sender and idempotent; the alert fires once per low *episode* (re-armed after the peer charges
/// or climbs above `rearmLevel`), so a duplicate/resynced report can't re-alert.
final class BatterySyncManager: ObservableObject {
    static let lowThreshold = 20
    static let rearmLevel = 30

    @Published private(set) var batteryBySenderId: [String: BatteryState] = [:]

    private weak var transportManager: TransportManager?
    private let identity: IdentityKeyStore
    private let featureSettings: FeatureSettings
    private let readBattery: () -> BatteryState?
    private let onLowBattery: (_ senderId: String, _ level: Int) -> Void
    private var lastReported: BatteryState?
    private var alerted = Set<String>()
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
        transportManager.router.register(prefix: "battery.update") { [weak self] envelope in
            DispatchQueue.main.async { self?.handleUpdate(envelope) }
        }
    }

    /// Starts reporting local changes (call once at launch).
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
    }

    /// Sends the current reading if it differs from the last one sent.
    func reportCurrentState() {
        guard featureSettings.isEnabled(.battery), let now = readBattery(), now != lastReported else { return }
        lastReported = now
        send(now)
    }

    /// Sends the current reading unconditionally — on every fresh connect and every 60s while
    /// connected, so a dropped or mis-timed report self-heals.
    func reportInitialSyncState() {
        guard featureSettings.isEnabled(.battery), let now = readBattery() else { return }
        lastReported = now
        send(now)
    }

    static func payload(sourceDeviceId: String, state: BatteryState) -> JSONValue {
        .object(["sourceDeviceId": .string(sourceDeviceId), "level": .number(Double(state.level)), "isCharging": .bool(state.isCharging)])
    }

    private func send(_ state: BatteryState) {
        let envelope = Envelope(type: "battery.update", senderId: identity.deviceId, broadcast: true,
                                payload: Self.payload(sourceDeviceId: identity.deviceId, state: state))
        try? transportManager?.send(envelope: envelope)
    }

    /// Main-thread only.
    func handleUpdate(_ envelope: Envelope) {
        guard let level = envelope.payload["level"]?.numberValue,
              let charging = envelope.payload["isCharging"]?.boolValue else { return }
        let clamped = max(0, min(100, Int(level)))
        let sender = envelope.senderId
        batteryBySenderId[sender] = BatteryState(level: clamped, isCharging: charging)
        if charging || clamped > Self.rearmLevel {
            alerted.remove(sender)
        } else if clamped <= Self.lowThreshold, alerted.insert(sender).inserted {
            onLowBattery(sender, clamped)
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
