import Foundation
import Combine

/// Implements the Android-facing half of `lock_on_leave.config` (see
/// `schema/message-types.md`) and the actual lock trigger. No message is needed for the
/// trigger itself: the Mac is always the BLE central for phones (`docs/ble-proximity-protocol.md`),
/// so it already knows directly, via `BLEProximityMonitor`, the instant a specific trusted
/// phone leaves confirmed range — `lock_on_leave.config` only carries the per-device
/// on/off setting itself.
///
/// Fires **once per range-loss transition**, not on every tick while a device stays out
/// of range, and enforces a cooldown per device on top of that — a device flapping in
/// and out right at the RSSI threshold must not repeatedly re-lock a screen the user has
/// since manually unlocked. See the memory note this session captured from the user's
/// own request: "shouldn't spam it... should still be able to unlock it."
final class LockOnLeaveManager {
    static let cooldown: TimeInterval = 30

    private let transportManager: TransportManager
    private let trustedDevicesStore: TrustedDevicesStore
    private let bleProximityMonitor: BLEProximityMonitor
    private var previousNearbyDeviceIds: Set<String> = []
    private var lastFiredAt: [String: Date] = [:]
    private var cancellable: AnyCancellable?
    var featureSettings: FeatureSettings = .shared

    init(
        transportManager: TransportManager,
        trustedDevicesStore: TrustedDevicesStore,
        bleProximityMonitor: BLEProximityMonitor
    ) {
        self.transportManager = transportManager
        self.trustedDevicesStore = trustedDevicesStore
        self.bleProximityMonitor = bleProximityMonitor
        self.previousNearbyDeviceIds = bleProximityMonitor.nearbyDeviceIds

        transportManager.router.register(prefix: "lock_on_leave.config") { [weak self] envelope in
            self?.handleConfig(envelope)
        }

        cancellable = bleProximityMonitor.$nearbyDeviceIds.sink { [weak self] newValue in
            self?.handleNearbyDeviceIdsChanged(newValue)
        }
    }

    private func handleConfig(_ envelope: Envelope) {
        guard let enabled = envelope.payload["enabled"]?.boolValue else { return }
        trustedDevicesStore.setLockOnLeaveEnabled(deviceId: envelope.senderId, enabled: enabled)
    }

    private func handleNearbyDeviceIdsChanged(_ newValue: Set<String>) {
        let justLeft = previousNearbyDeviceIds.subtracting(newValue)
        previousNearbyDeviceIds = newValue
        // Local BLE trigger (not a message), so the transport-level feature gate can't cover it.
        guard featureSettings.isEnabled(.lockOnLeave) else { return }

        for deviceId in justLeft {
            let device = trustedDevicesStore.device(for: deviceId)
            guard device?.lockOnLeaveEnabled == true else { continue }
            if let last = lastFiredAt[deviceId], Date().timeIntervalSince(last) < Self.cooldown {
                continue
            }
            lastFiredAt[deviceId] = Date()
            Self.lockScreen()
        }
    }

    /// Locks the screen via `SACLockScreenImmediate`, the private WindowServer-session
    /// function the now-removed `CGSession -suspend` CLI tool (what this project's handoff
    /// originally suggested investigating) itself called internally — confirmed still
    /// present via `dlopen`/`dlsym` on this machine even though `CGSession` the standalone
    /// binary is gone, and confirmed live to actually lock the screen. Deliberately not the
    /// AppleScript/System-Events `keystroke` route real menu-bar "lock" utilities usually
    /// use: that path requires the separate Accessibility TCC permission (distinct from
    /// plain Automation), and this project's ad-hoc code signature — unstable across every
    /// rebuild, the same root cause already documented for `IdentityKeyStore`'s Keychain
    /// workaround — left that permission stuck unable to even register in System Settings.
    /// A private API is an acceptable tradeoff here since this project isn't distributed
    /// through the App Store (no review gate to fail); revisit if that ever changes.
    private static func lockScreen() {
        typealias LockFunction = @convention(c) () -> Void
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/A/login", RTLD_NOW) else {
            gossipError("Gossip: " + "lockScreen: dlopen login.framework failed: \(dlerror().map { String(cString: $0) } ?? "unknown")")
            return
        }
        defer { dlclose(handle) }
        guard let sym = dlsym(handle, "SACLockScreenImmediate") else {
            gossipError("Gossip: " + "lockScreen: dlsym SACLockScreenImmediate failed")
            return
        }
        unsafeBitCast(sym, to: LockFunction.self)()
    }
}
