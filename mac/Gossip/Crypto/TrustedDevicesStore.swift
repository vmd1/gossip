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

    init(
        deviceId: String,
        publicKeyBase64: String,
        deviceName: String,
        deviceType: DeviceType,
        addedAt: Date,
        fallbackHost: String? = nil,
        lockOnLeaveEnabled: Bool = false,
        signingPublicKeyBase64: String? = nil
    ) {
        self.deviceId = deviceId
        self.publicKeyBase64 = publicKeyBase64
        self.deviceName = deviceName
        self.deviceType = deviceType
        self.addedAt = addedAt
        self.fallbackHost = fallbackHost
        self.lockOnLeaveEnabled = lockOnLeaveEnabled
        self.signingPublicKeyBase64 = signingPublicKeyBase64
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
    }
}

/// Persists the `TrustedDevices` table to a JSON file in
/// `~/Library/Application Support/Connect/trusted-devices.json`.
final class TrustedDevicesStore: ObservableObject {
    static let shared = TrustedDevicesStore()

    @Published private(set) var devices: [TrustedDevice] = []

    private let fileURL: URL
    private let revokedFileURL: URL
    /// Sticky tombstones: deviceId -> when it was revoked (Unix ms). Gossip can't re-add a
    /// revoked device unless the introduction is newer than the revocation, and pairing it
    /// directly again clears the tombstone.
    private var revoked: [String: Int64] = [:]
    private let queue = DispatchQueue(label: "dev.vmd1.gossip.trusteddevicesstore")

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
            self.revokedFileURL = fileURL.deletingLastPathComponent().appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent + "-revoked.json")
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            // Deliberately still "Connect", not "Gossip" — this is the on-disk
            // ~/Library/Application Support directory holding IdentityKeyStore's
            // device identity and TrustedDevicesStore's pairing state. Renaming it
            // would silently generate a new device identity and drop every already-
            // paired device, forcing a full re-pair across the whole mesh for no
            // benefit — not part of the Connect→Gossip rebrand's scope.
            let dir = appSupport.appendingPathComponent("Connect", isDirectory: true)
            PrivateFile.ensureDirectory(dir)
            self.fileURL = dir.appendingPathComponent("trusted-devices.json")
            self.revokedFileURL = dir.appendingPathComponent("revoked-devices.json")
        }
        load()
    }

    // MARK: - Public API

    func isTrusted(deviceId: String) -> Bool {
        queue.sync { devices.contains { $0.deviceId == deviceId } }
    }

    func device(for deviceId: String) -> TrustedDevice? {
        queue.sync { devices.first { $0.deviceId == deviceId } }
    }

    func allDevices() -> [TrustedDevice] {
        queue.sync { devices }
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
            devices.removeAll { $0.deviceId == deviceId }
            devices.append(device)
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
            guard let index = devices.firstIndex(where: { $0.deviceId == deviceId }),
                  devices[index].signingPublicKeyBase64 != signingPublicKeyBase64 else { return }
            devices[index].signingPublicKeyBase64 = signingPublicKeyBase64
            changed = true
        }
        guard changed else { return }
        persist()
        publishOnMain()
    }

    /// Removes the device and records a tombstone so gossip can't quietly bring it back.
    /// `revokedAt` is when the revocation happened (Unix ms); keeps the later of two.
    func revoke(deviceId: String, revokedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        queue.sync {
            devices.removeAll { $0.deviceId == deviceId }
            revoked[deviceId] = max(revoked[deviceId] ?? 0, revokedAt)
        }
        persist()
        publishOnMain()
    }

    func revokedAt(deviceId: String) -> Int64? {
        queue.sync { revoked[deviceId] }
    }

    func setFallbackHost(deviceId: String, fallbackHost: String?) {
        let trimmed = fallbackHost?.trimmingCharacters(in: .whitespacesAndNewlines)
        queue.sync {
            guard let index = devices.firstIndex(where: { $0.deviceId == deviceId }) else { return }
            devices[index].fallbackHost = (trimmed?.isEmpty == false) ? trimmed : nil
        }
        persist()
        publishOnMain()
    }

    /// Applies an incoming `lock_on_leave.config` from `deviceId` (see `schema/message-types.md`).
    /// No-ops if `deviceId` isn't trusted (e.g. a stale/racing message from a just-revoked device).
    func setLockOnLeaveEnabled(deviceId: String, enabled: Bool) {
        queue.sync {
            guard let index = devices.firstIndex(where: { $0.deviceId == deviceId }) else { return }
            devices[index].lockOnLeaveEnabled = enabled
        }
        persist()
        publishOnMain()
    }

    // MARK: - Persistence

    private func load() {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL) else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let decoded = try? decoder.decode([TrustedDevice].self, from: data) {
                devices = decoded
            }
            if let data = try? Data(contentsOf: revokedFileURL),
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
            guard let data = try? encoder.encode(devices) else { return }
            PrivateFile.write(data, to: fileURL)
            if let revokedData = try? JSONEncoder().encode(revoked) {
                PrivateFile.write(revokedData, to: revokedFileURL)
            }
        }
    }

    private func publishOnMain() {
        let snapshot = queue.sync { devices }
        DispatchQueue.main.async { [weak self] in
            self?.devices = snapshot
        }
    }
}
