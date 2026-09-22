import Foundation

enum DeviceType: String, Codable {
    case mac
    case androidPhone = "android-phone"
    case androidTablet = "android-tablet"
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
}

/// Persists the `TrustedDevices` table to a JSON file in
/// `~/Library/Application Support/Connect/trusted-devices.json`.
final class TrustedDevicesStore: ObservableObject {
    static let shared = TrustedDevicesStore()

    @Published private(set) var devices: [TrustedDevice] = []

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.connect.app.trusteddevicesstore")

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
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
    func addDevice(deviceId: String, publicKeyBase64: String, deviceName: String, deviceType: DeviceType) -> TrustedDevice {
        let device = TrustedDevice(
            deviceId: deviceId,
            publicKeyBase64: publicKeyBase64,
            deviceName: deviceName,
            deviceType: deviceType,
            addedAt: Date()
        )
        queue.sync {
            devices.removeAll { $0.deviceId == deviceId }
            devices.append(device)
        }
        persist()
        publishOnMain()
        return device
    }

    func revoke(deviceId: String) {
        queue.sync {
            devices.removeAll { $0.deviceId == deviceId }
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
