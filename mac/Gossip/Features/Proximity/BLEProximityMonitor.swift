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
    static let capabilityHotspotAvailable: UInt8 = 0x01
    static let capabilityHotspotOn: UInt8 = 0x02

    /// Trusted device IDs currently confirmed nearby over BLE.
    @Published private(set) var nearbyDeviceIds: Set<String> = []

    /// Last-observed "hotspot available" capability bit (advertisement byte 12 — see
    /// `docs/ble-proximity-protocol.md`) per scanned `deviceId`. Not proximity-debounced
    /// like `nearbyDeviceIds` — a capability signal doesn't need the same debounce a
    /// presence signal does — so combine with `nearbyDeviceIds` to answer "is this
    /// specific *nearby* device offering hotspot right now." Cleared the moment a
    /// device is no longer confirmed nearby, so a stale claim can't linger.
    private(set) var hotspotCapabilityByDeviceId: [String: Bool] = [:]

    /// Last-observed "hotspot currently on" capability bit — a BLE-only signal,
    /// independent of `hotspot.state_update`'s mesh broadcast (`HotspotStateManager`),
    /// so it stays accurate even with no mesh connection to that phone at all.
    /// Live-confirmed real gap this fixes: the mesh-only signal went stale the moment
    /// this Mac's mesh connection dropped, with nothing to correct it until
    /// reconnected — pressing the hotspot button against a stale "on" belief then sent
    /// the wrong request. Same proximity-scoping caveat as [hotspotCapabilityByDeviceId].
    private(set) var hotspotOnByDeviceId: [String: Bool] = [:]

    func isHotspotAvailable(deviceId: String) -> Bool {
        hotspotCapabilityByDeviceId[deviceId] == true
    }

    func isHotspotOn(deviceId: String) -> Bool {
        hotspotOnByDeviceId[deviceId] == true
    }

    /// The most recently observed `CBPeripheral.identifier` for `deviceId` — a
    /// requester needs this to open an actual GATT connection (`HotspotGattClient`)
    /// once it's decided, from `isHotspotAvailable`, that it wants to. Not the
    /// `CBPeripheral` object itself: CoreBluetooth peripheral objects are scoped to the
    /// `CBCentralManager` instance that discovered them, so `HotspotGattClient` (which
    /// owns its own manager instance, kept separate from this class's continuous
    /// proximity scan) re-resolves the peripheral from this identifier via its own
    /// `retrievePeripherals(withIdentifiers:)` instead of reusing this instance's
    /// object directly — the identifier itself is stable across manager instances on
    /// the same system, that part is fine to share.
    private(set) var peripheralIdentifierByDeviceId: [String: UUID] = [:]

    private var centralManager: CBCentralManager!
    private let trustedDevicesStore: TrustedDevicesStore
    /// Currently acceptable keyed beacon tags -> device; rebuilt when the roster/keys change and as the time window moves.
    private var fingerprintToDeviceId: [Data: String] = [:]
    private var tagMapWindow: UInt64 = .max
    private var knownDevices: [TrustedDevice] = []
    private var states: [String: ProximityState] = [:]
    private var storeSubscription: AnyCancellable?
    private var staleTimer: Timer?

    private struct ProximityState {
        var consecutiveStrongHits: Int = 0
        var lastSeenAt: Date = .distantPast
        var isInRange: Bool = false
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
        knownDevices = devices
        var map: [Data: String] = [:]
        for device in devices {
            guard let key = device.beaconKeyBase64.flatMap({ Data(base64Encoded: $0) }), key.count == 32 else { continue }
            for tag in BeaconTag.acceptableTags(key: key) { map[tag] = device.deviceId }
        }
        fingerprintToDeviceId = map
        tagMapWindow = BeaconTag.window()
    }

    /// The tags rotate every window, so the map is refreshed whenever the window has moved on.
    private func deviceId(forTag tag: Data) -> String? {
        if BeaconTag.window() != tagMapWindow { rebuildFingerprintMap(devices: knownDevices) }
        return fingerprintToDeviceId[tag]
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
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
            return
        }
        let companyId = UInt16(manufacturerData[0]) | (UInt16(manufacturerData[1]) << 8)
        guard companyId == Self.manufacturerId,
              manufacturerData[2] == Self.magic[0], manufacturerData[3] == Self.magic[1] else {
            return
        }
        let fingerprint = manufacturerData.subdata(in: 4..<12)
        guard let deviceId = deviceId(forTag: fingerprint) else {
            return
        }
        // Byte 12 (optional — a peer on an older build simply won't have it, which
        // isn't a malformed advertisement, just an absent capability signal).
        if manufacturerData.count >= 13 {
            hotspotCapabilityByDeviceId[deviceId] = (manufacturerData[12] & Self.capabilityHotspotAvailable) != 0
            hotspotOnByDeviceId[deviceId] = (manufacturerData[12] & Self.capabilityHotspotOn) != 0
        }
        peripheralIdentifierByDeviceId[deviceId] = peripheral.identifier
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
            states[deviceId]?.isInRange = false
            states[deviceId]?.consecutiveStrongHits = 0
            nearbyDeviceIds.remove(deviceId)
            hotspotCapabilityByDeviceId.removeValue(forKey: deviceId)
            hotspotOnByDeviceId.removeValue(forKey: deviceId)
            peripheralIdentifierByDeviceId.removeValue(forKey: deviceId)
        }
    }
}
