import Foundation

enum DeviceType: String, Codable {
    case mac
    case androidPhone = "android-phone"
    case androidTablet = "android-tablet"

    /// SF Symbol shown in place of the old plain-text device-type subtitle in `MenuBarView`.
    var symbolName: String {
        switch self {
        case .mac: return "laptopcomputer"
        case .androidPhone: return "iphone"
        case .androidTablet: return "ipad"
        }
    }
}

/// A single row of the `TrustedDevices` table: deviceId -> publicKey -> metadata.
///
/// This is deliberately a table, not a single "paired device" field, because
/// the long-term goal is a multi-device ecosystem (several phones/tablets/Macs
/// trusting each other). v1 will typically only ever populate one row per
/// install, but keeping the schema plural avoids a protocol/storage rewrite
/// later.
struct TrustedDevice: Codable, Identifiable, Equatable {
    var id: String { deviceId }
    let deviceId: String
    /// Base64-encoded raw X25519 public key (used to re-derive the Noise_IK session on reconnect).
    let publicKeyBase64: String
    var deviceName: String
    var deviceType: DeviceType
    let addedAt: Date
    /// User-entered fallback address (e.g. a Tailscale IP) to dial directly when normal
    /// on-LAN discovery can't reach this peer — see `TransportManager.connect(toFallbackHost:remoteStaticKey:)`.
    /// `nil`/blank means "not configured." Mirrors Android's `TrustedDevice.fallbackHost`.
    var fallbackHost: String? = nil
    /// Whether this Mac should lock its screen when *this* device (set from the Android
    /// side — see `lock_on_leave.config` in `schema/message-types.md`) leaves confirmed
    /// BLE range. Meaningless for a row where `deviceType == .mac`, since only phones
    /// advertise/are tracked by `BLEProximityMonitor`. Defaults to `false` and must decode
    /// safely when absent from an older persisted file — see the custom `init(from:)`
    /// below; a non-optional `Bool` with only a default *property* initializer (no custom
    /// decode) would make `JSONDecoder` throw on any pre-existing `trusted-devices.json`
    /// missing this key, and `TrustedDevicesStore.load()`'s `try?` would then silently
    /// wipe every already-paired device instead of just defaulting this one field.
    var lockOnLeaveEnabled: Bool = false
    /// This device's base64-encoded Ed25519 *signing* public key (distinct from
    /// `publicKeyBase64`, the X25519 key-agreement key used for Noise_IK) — used to
    /// verify signed GATT requests (e.g. Instant Hotspot's `hotspot.toggle_request`).
    /// `nil` for a row paired before this field existed; see
    /// `TrustedDevicesStore.backfillSigningPublicKey`. Decodes safely when absent from
    /// an older persisted file, same reasoning as `lockOnLeaveEnabled` above.
    var signingPublicKeyBase64: String? = nil
    /// The key this device uses to tag its BLE advertisements, shared over the encrypted mesh (`ble.beacon_key`);
    /// `nil` until it has been received. See `BeaconTag`.
    var beaconKeyBase64: String? = nil

    init(
        deviceId: String,
        publicKeyBase64: String,
        deviceName: String,
        deviceType: DeviceType,
        addedAt: Date,
        fallbackHost: String? = nil,
        lockOnLeaveEnabled: Bool = false,
        signingPublicKeyBase64: String? = nil,
        beaconKeyBase64: String? = nil
    ) {
        self.deviceId = deviceId
        self.publicKeyBase64 = publicKeyBase64
        self.deviceName = deviceName
        self.deviceType = deviceType
        self.addedAt = addedAt
        self.fallbackHost = fallbackHost
        self.lockOnLeaveEnabled = lockOnLeaveEnabled
        self.signingPublicKeyBase64 = signingPublicKeyBase64
        self.beaconKeyBase64 = beaconKeyBase64
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try container.decode(String.self, forKey: .deviceId)
        publicKeyBase64 = try container.decode(String.self, forKey: .publicKeyBase64)
        deviceName = try container.decode(String.self, forKey: .deviceName)
        deviceType = try container.decode(DeviceType.self, forKey: .deviceType)
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        fallbackHost = try container.decodeIfPresent(String.self, forKey: .fallbackHost)
        lockOnLeaveEnabled = try container.decodeIfPresent(Bool.self, forKey: .lockOnLeaveEnabled) ?? false
        signingPublicKeyBase64 = try container.decodeIfPresent(String.self, forKey: .signingPublicKeyBase64)
        beaconKeyBase64 = try container.decodeIfPresent(String.self, forKey: .beaconKeyBase64)
    }
}

/// Persists the `TrustedDevices` table (and the revocation tombstones) as JSON in the login Keychain, so another
/// process of the same user can't read the peers' beacon keys or add a trusted device by editing a file. The old
/// `~/Library/Application Support/Connect/{trusted-devices,revoked-devices}.json` files are migrated on first launch.
final class TrustedDevicesStore: ObservableObject {
    static let shared = TrustedDevicesStore()

    /// What the UI observes. Only ever assigned on the main thread (see `publishOnMain`): publishing it from the
    /// transport/gossip threads that mutate the store crashed SwiftUI's menu-bar item (`NSStatusItem.setVisible` off main).
    @Published private(set) var devices: [TrustedDevice] = []
    /// The source of truth, guarded by `queue`.
    private var storage: [TrustedDevice] = []

    private let devicesBlob: SecretBlobStore
    private let revokedBlob: SecretBlobStore
    /// Sticky tombstones: deviceId -> when it was revoked (Unix ms). Gossip can't re-add a
    /// revoked device unless the introduction is newer than the revocation, and pairing it
    /// directly again clears the tombstone.
    private var revoked: [String: Int64] = [:]
    private let queue = DispatchQueue(label: "dev.vmd1.gossip.trusteddevicesstore")

    init(devicesBlob: SecretBlobStore, revokedBlob: SecretBlobStore) {
        self.devicesBlob = devicesBlob
        self.revokedBlob = revokedBlob
        load()
    }

    /// File-backed store at `fileURL` (tombstones in a sibling `-revoked.json`); used by tests.
    convenience init(fileURL: URL) {
        let revokedURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent + "-revoked.json")
        self.init(devicesBlob: FileBlobStore(url: fileURL), revokedBlob: FileBlobStore(url: revokedURL))
    }

    /// The production store: Keychain, migrating from the legacy files.
    convenience init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        // Deliberately still "Connect", not "Gossip" — see `IdentityKeyStore.init()`.
        let dir = appSupport.appendingPathComponent("Connect", isDirectory: true)
        PrivateFile.ensureDirectory(dir)
        self.init(
            devicesBlob: ProductionBlobStore.make(account: "trusted-devices", legacyFile: dir.appendingPathComponent("trusted-devices.json")),
            revokedBlob: ProductionBlobStore.make(account: "revoked-devices", legacyFile: dir.appendingPathComponent("revoked-devices.json"))
        )
    }

    // MARK: - Public API

    func isTrusted(deviceId: String) -> Bool {
        queue.sync { storage.contains { $0.deviceId == deviceId } }
    }

    func device(for deviceId: String) -> TrustedDevice? {
        queue.sync { storage.first { $0.deviceId == deviceId } }
    }

    func allDevices() -> [TrustedDevice] {
        queue.sync { storage }
    }

    @discardableResult
    func addDevice(
        deviceId: String,
        publicKeyBase64: String,
        deviceName: String,
        deviceType: DeviceType,
        signingPublicKeyBase64: String? = nil
    ) -> TrustedDevice {
        let device = TrustedDevice(
            deviceId: deviceId,
            publicKeyBase64: publicKeyBase64,
            deviceName: deviceName,
            deviceType: deviceType,
            addedAt: Date(),
            signingPublicKeyBase64: signingPublicKeyBase64
        )
        queue.sync {
            storage.removeAll { $0.deviceId == deviceId }
            storage.append(device)
            revoked.removeValue(forKey: deviceId)
        }
        persist()
        publishOnMain()
        return device
    }

    /// Records the signing key a device presented inside an authenticated Noise
    /// handshake (it was bound to the static key this device was paired with). Replaces a
    /// missing value or one learned second-hand via gossip. Idempotent.
    func setSigningPublicKey(deviceId: String, signingPublicKeyBase64: String) {
        var changed = false
        queue.sync {
            guard let index = storage.firstIndex(where: { $0.deviceId == deviceId }),
                  storage[index].signingPublicKeyBase64 != signingPublicKeyBase64 else { return }
            storage[index].signingPublicKeyBase64 = signingPublicKeyBase64
            changed = true
        }
        guard changed else { return }
        persist()
        publishOnMain()
    }

    /// Removes the device and records a tombstone so gossip can't quietly bring it back.
    /// `revokedAt` is when the revocation happened (Unix ms); keeps the later of two.
    /// Records the beacon key a trusted device sent over the mesh. Idempotent; no-ops for an unknown device.
    func setBeaconKey(deviceId: String, beaconKeyBase64: String) {
        var changed = false
        queue.sync {
            guard let index = storage.firstIndex(where: { $0.deviceId == deviceId }),
                  storage[index].beaconKeyBase64 != beaconKeyBase64 else { return }
            storage[index].beaconKeyBase64 = beaconKeyBase64
            changed = true
        }
        guard changed else { return }
        persist()
        publishOnMain()
    }

    func revoke(deviceId: String, revokedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        queue.sync {
            storage.removeAll { $0.deviceId == deviceId }
            revoked[deviceId] = max(revoked[deviceId] ?? 0, revokedAt)
        }
        persist()
        publishOnMain()
    }

    func revokedAt(deviceId: String) -> Int64? {
        queue.sync { revoked[deviceId] }
    }

    /// Returns `false` (and changes nothing) if the address isn't a valid IP or hostname; blank clears it.
    @discardableResult
    func setFallbackHost(deviceId: String, fallbackHost: String?) -> Bool {
        let trimmed = fallbackHost?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty, !HostValidator.isValid(trimmed) { return false }
        queue.sync {
            guard let index = storage.firstIndex(where: { $0.deviceId == deviceId }) else { return }
            storage[index].fallbackHost = (trimmed?.isEmpty == false) ? trimmed : nil
        }
        persist()
        publishOnMain()
        return true
    }

    /// Applies an incoming `lock_on_leave.config` from `deviceId` (see `schema/message-types.md`).
    /// No-ops if `deviceId` isn't trusted (e.g. a stale/racing message from a just-revoked device).
    func setLockOnLeaveEnabled(deviceId: String, enabled: Bool) {
        queue.sync {
            guard let index = storage.firstIndex(where: { $0.deviceId == deviceId }) else { return }
            storage[index].lockOnLeaveEnabled = enabled
        }
        persist()
        publishOnMain()
    }

    // MARK: - Rust engine snapshot

    /// The trust table in the Rust engine's snapshot format (`desktop/core` `TrustSnapshot`): the engine is
    /// created from this and owns the live trust decisions, then reports changes back through `importCoreSnapshot`.
    /// App-only fields (fallback host, lock-on-leave) never go to the engine.
    func exportCoreSnapshot() -> String {
        let (devices, tombstones) = queue.sync { (storage, revoked) }
        let rows: [[String: Any]] = devices.map { d in
            var row: [String: Any] = [
                "device_id": d.deviceId,
                "public_key": d.publicKeyBase64,
                "device_name": d.deviceName,
                "device_type": d.deviceType.rawValue,
                "added_at": Int64(d.addedAt.timeIntervalSince1970 * 1000),
            ]
            row["signing_public_key"] = d.signingPublicKeyBase64 ?? NSNull()
            row["beacon_key"] = d.beaconKeyBase64 ?? NSNull()
            return row
        }
        let root: [String: Any] = ["devices": rows, "revoked": tombstones.mapValues { $0 as Any }]
        let data = (try? JSONSerialization.data(withJSONObject: root)) ?? Data("{\"devices\":[],\"revoked\":{}}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Applies a snapshot the engine reported after its trust changed (a pairing was confirmed, a roster introduced a
    /// device, a revocation arrived, a signing key was learned from a handshake). Existing rows keep their app-only
    /// fields; devices the engine has revoked are removed and tombstoned. Returns whether anything changed.
    @discardableResult
    func importCoreSnapshot(_ json: String) -> Bool {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let rows = root["devices"] as? [[String: Any]] else { return false }
        let tombstones = (root["revoked"] as? [String: Any])?.compactMapValues { ($0 as? NSNumber)?.int64Value } ?? [:]

        var changed = false
        queue.sync {
            var seen = Set<String>()
            for row in rows {
                guard let id = row["device_id"] as? String, let key = row["public_key"] as? String,
                      let name = row["device_name"] as? String, let typeRaw = row["device_type"] as? String else { continue }
                seen.insert(id)
                let signing = row["signing_public_key"] as? String
                if let index = storage.firstIndex(where: { $0.deviceId == id }) {
                    // The row exists: only the signing key (learned from an authenticated handshake) can have changed.
                    if let signing, storage[index].signingPublicKeyBase64 != signing {
                        storage[index].signingPublicKeyBase64 = signing
                        changed = true
                    }
                } else if let type = DeviceType(rawValue: typeRaw) {
                    // A device type this app has no case for (a future platform) can be trusted by the engine and
                    // relayed through, but has no row to show yet.
                    let ms = (row["added_at"] as? NSNumber)?.int64Value ?? Int64(Date().timeIntervalSince1970 * 1000)
                    storage.append(TrustedDevice(
                        deviceId: id, publicKeyBase64: key, deviceName: name, deviceType: type,
                        addedAt: Date(timeIntervalSince1970: TimeInterval(ms) / 1000), signingPublicKeyBase64: signing
                    ))
                    changed = true
                }
            }
            // Only a device the engine has tombstoned is removed. "Missing from the snapshot" is not enough: the app may
            // have added a row after the engine produced this snapshot, and that row must survive.
            let before = storage.count
            storage.removeAll { tombstones[$0.deviceId] != nil && !seen.contains($0.deviceId) }
            if storage.count != before { changed = true }
            for (id, at) in tombstones where (revoked[id] ?? Int64.min) < at {
                revoked[id] = at
                changed = true
            }
            // A device the engine trusts again (a direct re-pairing) is no longer tombstoned.
            for id in seen where revoked[id] != nil && tombstones[id] == nil {
                revoked.removeValue(forKey: id)
                changed = true
            }
        }
        guard changed else { return false }
        persist()
        publishOnMain()
        return true
    }

    // MARK: - Persistence

    private func load() {
        queue.sync {
            guard let data = devicesBlob.read() else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let decoded = try? decoder.decode([TrustedDevice].self, from: data) {
                storage = decoded
            }
            if let data = revokedBlob.read(),
               let decoded = try? JSONDecoder().decode([String: Int64].self, from: data) {
                revoked = decoded
            }
        }
    }

    private func persist() {
        queue.sync {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(storage) else { return }
            devicesBlob.write(data)
            if let revokedData = try? JSONEncoder().encode(revoked) {
                revokedBlob.write(revokedData)
            }
        }
    }

    private func publishOnMain() {
        let snapshot = queue.sync { storage }
        if Thread.isMainThread { devices = snapshot; return }
        DispatchQueue.main.async { [weak self] in
            self?.devices = snapshot
        }
    }
}
