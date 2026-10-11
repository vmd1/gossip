import Foundation
import Combine
import GossipCoreKit

/// Implements the Android-facing half of the `lock_on_leave.config` state slot (see
/// `schema/message-types.md`) and the actual lock trigger. No message is needed for the
/// trigger itself: the Mac is always the BLE central for phones (`docs/ble-proximity-protocol.md`),
/// so it already knows directly, via `BLEProximityMonitor`, the instant a specific trusted
/// phone leaves confirmed range — the slot only lists which computers a phone armed.
///
/// Fires **once per range-loss transition**, not on every tick while a device stays out
/// of range, and enforces a cooldown per device on top of that — a device flapping in
/// and out right at the RSSI threshold must not repeatedly re-lock a screen the user has
/// since manually unlocked. The edge trigger and the cooldown are the core's `LockOnLeave`
/// (`desktop/core/src/features/lock_on_leave.rs`).
final class LockOnLeaveManager {
    static let cooldown: TimeInterval = TimeInterval(GossipCoreKit.lockOnLeaveCooldownMs()) / 1000

    private let transportManager: TransportManager
    private let trustedDevicesStore: TrustedDevicesStore
    private let bleProximityMonitor: BLEProximityMonitor
    private let logic: GossipCoreKit.LockOnLeave
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
        self.logic = GossipCoreKit.LockOnLeave(initiallyNearby: Array(bleProximityMonitor.nearbyDeviceIds))
        let me = IdentityKeyStore.shared.deviceId

        // A phone arms lock-on-leave for the computers it lists in its `lock_on_leave.config` slot (cleared, or the phone
        // was revoked: nothing armed).
        transportManager.addOnStateChanged { [weak self] change in
            guard change.slot == GossipCoreKit.lockOnLeaveSlot() else { return }
            let armed = change.valueJSON.flatMap { try? GossipCoreKit.lockOnLeaveIsArmedFor(valueJson: $0, me: me) } ?? false
            self?.trustedDevicesStore.setLockOnLeaveEnabled(deviceId: change.deviceId, enabled: armed)
        }

        cancellable = bleProximityMonitor.$nearbyDeviceIds.sink { [weak self] newValue in
            self?.handleNearbyDeviceIdsChanged(newValue)
        }
    }

    private func handleNearbyDeviceIdsChanged(_ newValue: Set<String>) {
        // Local BLE trigger (not a message), so the transport-level feature gate can't cover it.
        let armed = trustedDevicesStore.allDevices().filter { $0.lockOnLeaveEnabled }.map(\.deviceId)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if logic.nearbyChanged(nearby: Array(newValue), nowMs: nowMs, featureEnabled: featureSettings.isEnabled(.lockOnLeave), armed: armed) {
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
