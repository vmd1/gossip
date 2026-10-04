import Foundation
import CryptoKit

/// Keyed, rotating BLE proximity advertisements. A phone no longer advertises a constant hash of its
/// public key (which anyone who knows that key could replay, and any passer-by could track); it
/// advertises `tag(beaconKey, window)` — 8 bytes of HMAC-SHA256 over a 2-minute time window — and only
/// devices it has shared its `beaconKey` with (over the Noise-encrypted mesh, see `BeaconKeyManager`)
/// can recognise it. Android has the same functions (`BeaconTag.kt`); both are checked against
/// `schema/ble-beacon-vectors.json`. See `docs/ble-proximity-protocol.md`.
enum BeaconTag {
    static let windowSeconds: UInt64 = 120
    private static let label = Data("gossip-ble-v1".utf8)

    static func window(at date: Date = Date()) -> UInt64 {
        UInt64(max(0, date.timeIntervalSince1970)) / windowSeconds
    }

    static func tag(key: Data, window: UInt64) -> Data {
        var message = label
        withUnsafeBytes(of: window.bigEndian) { message.append(contentsOf: $0) }
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))
        return Data(Array(mac).prefix(8))
    }

    /// Tags a device holding `key` may be advertising right now, allowing one window of clock skew either way.
    static func acceptableTags(key: Data, at date: Date = Date()) -> [Data] {
        let w = window(at: date)
        return [w &- 1, w, w &+ 1].map { tag(key: key, window: $0) }
    }

    /// Seconds until the current window ends, so an advertiser can re-arm with the next tag on time.
    static func secondsUntilNextWindow(at date: Date = Date()) -> TimeInterval {
        let t = date.timeIntervalSince1970
        return TimeInterval(windowSeconds) - t.truncatingRemainder(dividingBy: TimeInterval(windowSeconds))
    }
}

/// Implements `ble.beacon_key`: tells every directly-connected trusted peer this device's beacon key (so they can
/// recognise its advertisements) and stores the keys peers send. State configured on the recipient, so it
/// self-heals like `trust.roster_update`: resent on every fresh connect and on a 5-minute resync; handling it
/// twice is a no-op.
final class BeaconKeyManager {
    private let transportManager: TransportManager
    private let trustedDevices: TrustedDevicesStore
    private let identity = IdentityKeyStore.shared

    init(transportManager: TransportManager, trustedDevices: TrustedDevicesStore = .shared) {
        self.transportManager = transportManager
        self.trustedDevices = trustedDevices
        transportManager.router.register(prefix: "ble.beacon_key") { [weak self] envelope in
            self?.handle(envelope)
        }
        transportManager.addOnTrustedConnected { [weak self] peer in
            self?.send(to: peer.deviceId)
        }
    }

    func periodicResync() {
        for device in trustedDevices.allDevices() { send(to: device.deviceId) }
    }

    private func send(to deviceId: String) {
        let envelope = Envelope(
            type: "ble.beacon_key",
            senderId: identity.deviceId,
            recipientId: deviceId,
            ttl: 0, // key material: direct connections only
            payload: .object(["key": .string(identity.beaconKey.base64EncodedString())])
        )
        try? transportManager.send(envelope: envelope)
    }

    private func handle(_ envelope: Envelope) {
        guard let base64 = envelope.payload["key"]?.stringValue,
              let key = Data(base64Encoded: base64), key.count == 32,
              trustedDevices.isTrusted(deviceId: envelope.senderId) else { return }
        trustedDevices.setBeaconKey(deviceId: envelope.senderId, beaconKeyBase64: base64)
    }
}
