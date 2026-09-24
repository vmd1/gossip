import Foundation
import CoreBluetooth
import CryptoKit
import Combine

/// Detects when a specific trusted device is within confirmed BLE range — the shared
/// primitive behind lock-on-leave and Instant Hotspot (see `docs/ble-proximity-protocol.md`
/// for the wire-level advertisement format and threshold rationale). Generic over
/// `DeviceType` in spirit even though, today, Mac only ever plays the central/scanning
/// role: it never advertises, so this type has no peripheral-manager half.
///
/// "Confirmed" means 2 consecutive advertisements at RSSI ≥ `Self.rssiThreshold`
/// before a device is reported nearby, and `Self.lossTimeout` seconds of silence before
/// it's reported as having left — a single strong or weak reading never flips
/// `nearbyDeviceIds` on its own. See the protocol doc for why: Wi-Fi connection drops
/// are common and unrelated to physical distance, so this primitive exists specifically
/// to *not* share that noisiness. Started at 3s, but confirmed live that a transient
/// signal gap of a few seconds — not an actual departure — can happen on real hardware
/// and falsely trip a 3s window; 6s is the current tradeoff between latency and that
/// false-positive risk. At a ~100ms advertise interval this is still ~60 consecutive
/// missed advertisements before firing, not a hair-trigger.
final class BLEProximityMonitor: NSObject, ObservableObject, CBCentralManagerDelegate {
    static let manufacturerId: UInt16 = 0xFFFF
    static let magic: [UInt8] = [0x43, 0x6E] // ASCII "Cn"
    static let rssiThreshold = -75
    static let confirmHitCount = 2
    static let lossTimeout: TimeInterval = 6

    /// Trusted device IDs currently confirmed nearby over BLE.
    @Published private(set) var nearbyDeviceIds: Set<String> = []

    private var centralManager: CBCentralManager!
    private let trustedDevicesStore: TrustedDevicesStore
    private var fingerprintToDeviceId: [Data: String] = [:]
    private var states: [String: ProximityState] = [:]
    private var storeSubscription: AnyCancellable?
    private var staleTimer: Timer?

    private struct ProximityState {
        var consecutiveStrongHits: Int = 0
        var lastSeenAt: Date = .distantPast
        var isInRange: Bool = false
    }

    // TEMPORARY debug logging while diagnosing a live BLE-detection issue — NSLog/`log show`
    // produced no output at all for this process, so this writes plain text directly to a
    // file inside the sandbox container instead. Remove once the underlying issue is found.
    private static let debugLogURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Connect", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ble-debug.log")
    }()

    static func debugLog(_ message: String) {
        let line = "\(Date()) \(message)\n"
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: debugLogURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: debugLogURL)
            }
        }
    }

    init(trustedDevicesStore: TrustedDevicesStore) {
        self.trustedDevicesStore = trustedDevicesStore
        super.init()
        rebuildFingerprintMap(devices: trustedDevicesStore.devices)
        storeSubscription = trustedDevicesStore.$devices.sink { [weak self] devices in
            self?.rebuildFingerprintMap(devices: devices)
        }
        centralManager = CBCentralManager(delegate: self, queue: .main)
        // `.common` (not the default `Timer.scheduledTimer` mode) so this keeps firing while
        // the menu-bar dropdown is open — a plain `.default`-mode timer is paused for as long
        // as the run loop is in `.eventTracking` mode, which a `MenuBarExtra(.window)` panel's
        // own tracking enters while it's open/being interacted with. Confirmed live: staleness
        // detection appeared to stop working entirely once the dropdown was kept open to watch
        // for it, and resumed once closed — this is why.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.checkForStaleDevices()
        }
        RunLoop.main.add(timer, forMode: .common)
        staleTimer = timer
    }

    private func rebuildFingerprintMap(devices: [TrustedDevice]) {
        var map: [Data: String] = [:]
        for device in devices {
            guard let keyData = Data(base64Encoded: device.publicKeyBase64) else { continue }
            let fingerprint = Data(SHA256.hash(data: keyData).prefix(8))
            map[fingerprint] = device.deviceId
        }
        fingerprintToDeviceId = map
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Self.debugLog("centralManagerDidUpdateState: \(central.state.rawValue)")
        guard central.state == .poweredOn else { return }
        // No service-UUID filter: the advertisement payload has no room for an
        // 18-byte 128-bit-UUID AD structure alongside the manufacturer data AD
        // structure within the legacy 31-byte budget (see the protocol doc), so
        // filtering happens here instead, on the manufacturer ID + magic prefix.
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else { return }
        guard manufacturerData.count >= 12 else {
            Self.debugLog("didDiscover: manufacturerData too short (\(manufacturerData.count) bytes) rssi=\(RSSI)")
            return
        }
        let companyId = UInt16(manufacturerData[0]) | (UInt16(manufacturerData[1]) << 8)
        guard companyId == Self.manufacturerId,
              manufacturerData[2] == Self.magic[0], manufacturerData[3] == Self.magic[1] else {
            Self.debugLog("didDiscover: companyId=\(String(format: "0x%04X", companyId)) magic mismatch rssi=\(RSSI)")
            return
        }
        let fingerprint = manufacturerData.subdata(in: 4..<12)
        guard let deviceId = fingerprintToDeviceId[fingerprint] else {
            Self.debugLog("didDiscover: unrecognized fingerprint \(fingerprint.map { String(format: "%02x", $0) }.joined()) rssi=\(RSSI); known=\(fingerprintToDeviceId.keys.map { $0.map { String(format: "%02x", $0) }.joined() })")
            return
        }
        Self.debugLog("didDiscover: MATCH deviceId=\(deviceId) rssi=\(RSSI)")
        recordDetection(deviceId: deviceId, rssi: RSSI.intValue)
    }

    private func recordDetection(deviceId: String, rssi: Int) {
        var state = states[deviceId] ?? ProximityState()
        // `lastSeenAt` only advances on readings that clear the RSSI floor — confirmed
        // live this needs to be RSSI-gated, not "any advertisement at all": a device
        // sitting right at the boundary keeps advertising at a weak-but-nonzero RSSI, and
        // if *any* reception counted as "seen" the loss-timeout would never fire no matter
        // how weak the signal got, since something was still arriving. Weak/absent signal
        // both need to count the same way toward "leaving."
        if rssi >= Self.rssiThreshold {
            state.lastSeenAt = Date()
            state.consecutiveStrongHits += 1
        } else {
            state.consecutiveStrongHits = 0
        }

        if !state.isInRange && state.consecutiveStrongHits >= Self.confirmHitCount {
            state.isInRange = true
            nearbyDeviceIds.insert(deviceId)
        }
        states[deviceId] = state
    }

    private func checkForStaleDevices() {
        let now = Date()
        for (deviceId, state) in states where state.isInRange {
            let elapsed = now.timeIntervalSince(state.lastSeenAt)
            guard elapsed > Self.lossTimeout else { continue }
            Self.debugLog("checkForStaleDevices: marking \(deviceId) OUT OF RANGE (elapsed=\(elapsed)s)")
            states[deviceId]?.isInRange = false
            states[deviceId]?.consecutiveStrongHits = 0
            nearbyDeviceIds.remove(deviceId)
        }
    }
}
