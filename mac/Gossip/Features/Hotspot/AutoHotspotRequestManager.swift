import Foundation

/// The automatic half of Instant Hotspot (see `docs/ble-hotspot-protocol.md`'s "Not yet
/// built" section, now built): when `WanReachabilityMonitor` reports this Mac has been
/// offline for a while, automatically fires the same signed `hotspot.toggle_request` GATT
/// flow the manual hotspot button uses (`HotspotGattClient.requestToggle`) against a
/// nearby, eligible, opted-in phone — no click needed. Mirrors Android's
/// `AutoHotspotRequestManager`.
///
/// Two separate opt-in gates, both local-only and never sent over the wire:
/// - `OnboardingPreferences.autoRequestHotspotEnabled` — whether this Mac auto-requests at
///   all.
/// - `TrustedDevice.autoHotspotRequestEligible` — per trusted phone, whether it's a
///   candidate target.
///
/// Candidate selection: any BLE-nearby trusted phone (`BLEProximityMonitor.
/// nearbyDeviceIds` — Mac already scans continuously, unlike a requesting Android phone,
/// so there's no on-demand-scan branch to mirror here) that's currently advertising the
/// hotspot-available capability bit, isn't already showing hotspot-on, and has the
/// per-phone eligibility flag set. First match wins — deliberately no fancier tiebreak.
///
/// A cooldown after each attempt (success or failure) prevents a flapping WAN connection
/// from re-firing a fresh request every offline episode in quick succession; only one
/// request is ever in flight at a time, mirroring the manual button's own
/// `hotspotGattClients` single-entry-per-device assumption.
///
/// Deliberately does **not** auto-*turn off* the hotspot once back online — not specified
/// by the handoff, and auto-shutoff has its own false-negative risk (a brief WAN blip
/// shouldn't yank a hotspot connection out from under active use). The manual toggle/icon
/// still controls turning it off.
final class AutoHotspotRequestManager {
    private static let cooldown: TimeInterval = 60

    private let trustedDevicesStore: TrustedDevicesStore
    private let bleProximityMonitor: BLEProximityMonitor
    private let wanReachabilityMonitor = WanReachabilityMonitor()

    private var lastAttemptAt = Date.distantPast
    private var attemptInFlight = false
    private var activeClient: HotspotGattClient?
    private var activeAutoConnect: HotspotAutoConnect?

    init(trustedDevicesStore: TrustedDevicesStore, bleProximityMonitor: BLEProximityMonitor) {
        self.trustedDevicesStore = trustedDevicesStore
        self.bleProximityMonitor = bleProximityMonitor
    }

    func start() {
        wanReachabilityMonitor.onWentOffline = { [weak self] in self?.onWentOffline() }
        wanReachabilityMonitor.start()
    }

    private func onWentOffline() {
        guard OnboardingPreferences.autoRequestHotspotEnabled else { return }
        guard !attemptInFlight else { return }
        guard Date().timeIntervalSince(lastAttemptAt) >= Self.cooldown else { return }
        attemptAutoRequest()
    }

    private func attemptAutoRequest() {
        guard let candidate = findCandidate(),
              let peripheralId = bleProximityMonitor.peripheralIdentifierByDeviceId[candidate.deviceId] else {
            return
        }
        attemptInFlight = true
        lastAttemptAt = Date()
        let client = HotspotGattClient()
        activeClient = client
        client.requestToggle(providerId: candidate.deviceId, peripheralIdentifier: peripheralId, enable: true) { [weak self] result in
            DispatchQueue.main.async {
                self?.activeClient = nil
                self?.attemptInFlight = false
                self?.handleResult(result)
            }
        }
    }

    private func handleResult(_ result: HotspotGattClient.Result) {
        switch result {
        case .failed:
            break
        case .success(let enabled, let ssid, let passphrase):
            guard enabled, let ssid, let passphrase else { return }
            let autoConnect = HotspotAutoConnect()
            activeAutoConnect = autoConnect
            autoConnect.connect(ssid: ssid, passphrase: passphrase) { _ in }
        }
    }

    /// Mac already scans continuously (`BLEProximityMonitor`'s only role), so
    /// `nearbyDeviceIds` alone answers "which nearby trusted phone offers hotspot" — no
    /// on-demand scan branch needed, unlike Android's requesting-phone case.
    private func findCandidate() -> TrustedDevice? {
        for deviceId in bleProximityMonitor.nearbyDeviceIds {
            guard bleProximityMonitor.isHotspotAvailable(deviceId: deviceId),
                  !bleProximityMonitor.isHotspotOn(deviceId: deviceId),
                  let device = trustedDevicesStore.device(for: deviceId),
                  device.deviceType == .androidPhone,
                  device.autoHotspotRequestEligible else { continue }
            return device
        }
        return nil
    }
}
