import Foundation
import GossipCoreKit

/// Keyed, rotating BLE proximity advertisements. A phone no longer advertises a constant hash of its
/// public key (which anyone who knows that key could replay, and any passer-by could track); it
/// advertises `tag(beaconKey, window)` — 8 bytes of HMAC-SHA256 over a 1-minute time window — and only
/// devices it has shared its `beaconKey` with (over the Noise-encrypted mesh, see `BeaconKeyManager`)
/// can recognise it. Android has the same functions (`BeaconTag.kt`); both are checked against
/// `schema/ble-beacon-vectors.json`. See `docs/ble-proximity-protocol.md`.
enum BeaconTag {
    // The tag function and the window are the core's (`desktop/core/src/crypto/beacon.rs`), shared with every platform.
    static let windowSeconds: UInt64 = 60

    static func window(at date: Date = Date()) -> UInt64 {
        GossipCoreKit.bleBeaconWindow(unixSeconds: UInt64(max(0, date.timeIntervalSince1970)))
    }

    static func tag(key: Data, window: UInt64) -> Data {
        GossipCoreKit.bleBeaconTag(key: key, window: window)
    }

    /// Tags a device holding `key` may be advertising right now, allowing one window of clock skew either way.
    static func acceptableTags(key: Data, at date: Date = Date()) -> [Data] {
        GossipCoreKit.bleAcceptableTags(key: key, unixSeconds: UInt64(max(0, date.timeIntervalSince1970)))
    }

    /// Seconds until the current window ends, so an advertiser can re-arm with the next tag on time.
    static func secondsUntilNextWindow(at date: Date = Date()) -> TimeInterval {
        TimeInterval(GossipCoreKit.bleSecondsUntilNextWindow(unixSeconds: UInt64(max(0, date.timeIntervalSince1970))))
    }
}

/// Shares this device's BLE beacon key with its directly connected trusted peers (so they can recognise its advertisements)
/// and stores the keys peers share. The key is the **direct-only** `direct.ble.beacon_key` state slot (see
/// `docs/plans/state-sync.md`): the core sends it only to devices connected straight to this one, never through the mesh,
/// and keeps it correct across reconnects, so nothing here resends it.
final class BeaconKeyManager {
    private let transportManager: TransportManager
    private let trustedDevices: TrustedDevicesStore
    private let identity = IdentityKeyStore.shared

    init(transportManager: TransportManager, trustedDevices: TrustedDevicesStore = .shared) {
        self.transportManager = transportManager
        self.trustedDevices = trustedDevices
        transportManager.addOnStateChanged { [weak self] change in
            guard change.slot == GossipCoreKit.beaconKeySlot() else { return }
            self?.handle(deviceId: change.deviceId, valueJSON: change.valueJSON)
        }
        if let value = try? GossipCoreKit.beaconKeyPayload(key: identity.beaconKey) {
            transportManager.setState(slot: GossipCoreKit.beaconKeySlot(), valueJSON: value)
        }
    }

    private func handle(deviceId: String, valueJSON: String?) {
        guard let valueJSON, let key = GossipCoreKit.beaconKeyParse(valueJson: valueJSON),
              trustedDevices.isTrusted(deviceId: deviceId) else { return }
        trustedDevices.setBeaconKey(deviceId: deviceId, beaconKeyBase64: key.base64EncodedString())
    }
}
