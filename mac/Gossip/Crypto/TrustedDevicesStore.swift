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
    private let queue = DispatchQueue(label: "dev.vmd1.gossip.trusteddevicesstore")

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            // Deliberately still "Connect", not "Gossip" — this is the on-disk
            // ~/Library/Application Support directory holding IdentityKeyStore's
            // device identity and TrustedDevicesStore's pairing state. Renaming it
            // would silently generate a new device identity and drop every already-
            // paired device, forcing a full re-pair across the whole mesh for no
            // benefit — not part of the Connect→Gossip rebrand's scope.
            let dir = appSupport.appendingPathComponent("Connect", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("trusted-devices.json")
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
        }
        persist()
        publishOnMain()
        return device
    }

    /// Fills in `TrustedDevice.signingPublicKeyBase64` for a row paired before that
    /// field existed, learned later via `trust.roster_update` gossip. No-ops if
    /// `deviceId` isn't trusted or already has a signing key on file — never
    /// overwrites an already-known key with a gossiped one, same "never clobber" rule
    /// `RosterGossipManager` applies to every other field on an already-trusted row.
    /// Idempotent: re-applying the same key is a no-op after the first call.
    func backfillSigningPublicKey(deviceId: String, signingPublicKeyBase64: String) {
        queue.sync {
            guard let index = devices.firstIndex(where: { $0.deviceId == deviceId }),
                  devices[index].signingPublicKeyBase64 == nil else { return }
            devices[index].signingPublicKeyBase64 = signingPublicKeyBase64
        }
        persist()
        publishOnMain()
    }

    func revoke(deviceId: String) {
        queue.sync {
            devices.removeAll { $0.deviceId == deviceId }
        }
        persist()
        publishOnMain()
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
        }
    }

    private func persist() {
        queue.sync {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(devices) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func publishOnMain() {
        let snapshot = queue.sync { devices }
        DispatchQueue.main.async { [weak self] in
            self?.devices = snapshot
        }
    }
}
