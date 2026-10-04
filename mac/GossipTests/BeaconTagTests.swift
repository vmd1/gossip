import XCTest
@testable import Gossip

final class BeaconTagTests: XCTestCase {
    private func data(hex: String) -> Data {
        Data(stride(from: 0, to: hex.count, by: 2).map { i in
            UInt8(hex[hex.index(hex.startIndex, offsetBy: i)..<hex.index(hex.startIndex, offsetBy: i + 2)], radix: 16)!
        })
    }

    func testTagsMatchTheSharedVectors() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("schema/ble-beacon-vectors.json")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let key = data(hex: root["keyHex"] as! String)
        XCTAssertEqual(UInt64(root["windowSeconds"] as! Int), BeaconTag.windowSeconds)
        for c in root["cases"] as! [[String: Any]] {
            XCTAssertEqual(BeaconTag.tag(key: key, window: UInt64(c["window"] as! Int)), data(hex: c["tagHex"] as! String))
        }
    }

    func testAcceptableTagsCoverOneWindowOfSkewAndRotate() {
        let key = Data(repeating: 7, count: 32)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let w = BeaconTag.window(at: now)
        let tags = BeaconTag.acceptableTags(key: key, at: now)
        XCTAssertEqual(tags.count, 3)
        XCTAssertTrue(tags.contains(BeaconTag.tag(key: key, window: w)))
        XCTAssertTrue(tags.contains(BeaconTag.tag(key: key, window: w - 1)))
        XCTAssertTrue(tags.contains(BeaconTag.tag(key: key, window: w + 1)))
        XCTAssertFalse(tags.contains(BeaconTag.tag(key: key, window: w + 2)))
        // A different key (an outsider who only knows the public key) matches nothing.
        XCTAssertTrue(Set(BeaconTag.acceptableTags(key: Data(repeating: 8, count: 32), at: now)).isDisjoint(with: Set(tags)))
        let left = BeaconTag.secondsUntilNextWindow(at: now)
        XCTAssertTrue(left > 0 && left <= 120)
    }

    func testBeaconKeyIsStoredIdempotentlyAndIgnoredForUnknownDevices() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bk-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-revoked.json"))
        }
        let store = TrustedDevicesStore(fileURL: url)
        store.addDevice(deviceId: "a", publicKeyBase64: "k", deviceName: "d", deviceType: .androidPhone)
        let key = Data(repeating: 3, count: 32).base64EncodedString()
        store.setBeaconKey(deviceId: "a", beaconKeyBase64: key)
        store.setBeaconKey(deviceId: "a", beaconKeyBase64: key)
        store.setBeaconKey(deviceId: "unknown", beaconKeyBase64: key)
        XCTAssertEqual(store.device(for: "a")?.beaconKeyBase64, key)
        XCTAssertNil(store.device(for: "unknown"))
        XCTAssertEqual(TrustedDevicesStore(fileURL: url).device(for: "a")?.beaconKeyBase64, key) // persisted
    }

    func testIdentityBeaconKeyIsGeneratedOnceAndSurvivesReload() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("id-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = IdentityKeyStore(fileURL: url)
        let key = first.beaconKey
        XCTAssertEqual(key.count, 32)
        XCTAssertEqual(first.beaconKey, key)
        XCTAssertEqual(IdentityKeyStore(fileURL: url).beaconKey, key)
    }
}
