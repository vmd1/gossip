import Foundation
import CoreWLAN
import CoreLocation

/// Joins a Wi-Fi network given SSID+passphrase credentials received over Instant
/// Hotspot's GATT channel (`docs/ble-hotspot-protocol.md`) — the requesting side's half
/// of credential auto-connect, for a Mac requester (Android's equivalent is
/// `HotspotAutoConnect.kt`/`WifiNetworkSpecifier`).
///
/// `CWInterface.associate(toNetwork:password:)` is the real API for this, but it's gated
/// behind Location Services authorization (a macOS-wide requirement for any app that
/// scans for or joins Wi-Fi networks programmatically, unrelated to what Connect actually
/// uses location for — see the `NSLocationWhenInUseUsageDescription` string in
/// `Info.plist`). **Live-verified working end to end** — a real request auto-connected
/// this Mac to a phone's hotspot. Getting there needed two real fixes beyond the request/
/// authorization logic itself, both confirmed live:
/// - The app is sandboxed (`com.apple.security.app-sandbox`), which needs the explicit
///   `com.apple.security.personal-information.location` entitlement for Location Services
///   to work *at all* — without it, requesting authorization silently never showed a
///   system prompt (stuck at `.notDetermined` forever, no dialog, no delegate callback).
///   The Info.plist usage-description string alone is necessary but not sufficient for a
///   sandboxed app.
/// - `requestAlwaysAuthorization()` also never prompted on macOS even with the
///   entitlement present; `requestWhenInUseAuthorization()` does, and `.authorizedWhenInUse`
///   is genuinely sufficient for this feature anyway (a single scan+associate, not
///   continuous background location access).
final class HotspotAutoConnect: NSObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private var authorizationContinuation: ((Bool) -> Void)?
    private var authorizationTimeoutWorkItem: DispatchWorkItem?

    override init() {
        super.init()
        locationManager.delegate = self
    }

    /// Requests Location Services authorization (if not already granted) and then joins
    /// [ssid] with [passphrase]. Calls `completion` with whether the join succeeded.
    func connect(ssid: String, passphrase: String, completion: @escaping (Bool) -> Void) {
        ensureLocationAuthorization { [weak self] authorized in
            guard authorized else {
                completion(false)
                return
            }
            self?.associate(ssid: ssid, passphrase: passphrase, completion: completion)
        }
    }

    private func ensureLocationAuthorization(completion: @escaping (Bool) -> Void) {
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            completion(true)
        case .denied, .restricted:
            completion(false)
        case .notDetermined:
            // Live-confirmed real bug: `requestAlwaysAuthorization()` never showed a
            // system prompt at all on macOS — no dialog, no delegate callback, nothing
            // (silently stuck at `.notDetermined` forever). `.authorizedWhenInUse` is
            // genuinely sufficient here anyway: this only ever needs one-time
            // authorization to do a single scan+associate, not continuous background
            // location access, so `requestWhenInUseAuthorization()` (matching the
            // `NSLocationWhenInUseUsageDescription` key already in Info.plist) is both
            // the fix and the more correct ask for what this feature actually needs.
            authorizationContinuation = completion
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.authorizationContinuation != nil else { return }
                self.authorizationContinuation = nil
                completion(false)
            }
            authorizationTimeoutWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
            locationManager.requestWhenInUseAuthorization()
        @unknown default:
            completion(false)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationTimeoutWorkItem?.cancel()
        authorizationTimeoutWorkItem = nil
        guard let continuation = authorizationContinuation else { return }
        authorizationContinuation = nil
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            continuation(true)
        default:
            continuation(false)
        }
    }

    private func associate(ssid: String, passphrase: String, completion: @escaping (Bool) -> Void) {
        guard let interface = CWWiFiClient.shared().interface() else {
            NSLog("Gossip: " + "HotspotAutoConnect: no Wi-Fi interface available")
            completion(false)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let scanResults = try interface.scanForNetworks(withSSID: ssid.data(using: .utf8))
                guard let network = scanResults.first else {
                    NSLog("Gossip: " + "HotspotAutoConnect: scan for '\(ssid)' found no matching network")
                    DispatchQueue.main.async { completion(false) }
                    return
                }
                try interface.associate(to: network, password: passphrase)
                DispatchQueue.main.async { completion(true) }
            } catch {
                NSLog("Gossip: " + "HotspotAutoConnect: failed: \(error)")
                DispatchQueue.main.async { completion(false) }
            }
        }
    }
}
