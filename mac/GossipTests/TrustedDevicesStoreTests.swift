import XCTest
@testable import Gossip

final class TrustedDevicesStoreTests: XCTestCase {

    private func makeTempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("connect-tests-\(UUID().uuidString)")
            .appendingPathExtension("json")
    }

    override func tearDown() {
        super.tearDown()
    }

    func testAddDeviceIsTrustedAndListed() {
        let url = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = TrustedDevicesStore(fileURL: url)

        XCTAssertTrue(store.allDevices().isEmpty)
        XCTAssertFalse(store.isTrusted(deviceId: "device-1"))

        store.addDevice(deviceId: "device-1", publicKeyBase64: "abc123==", deviceName: "Pixel 9", deviceType: .androidPhone)

        XCTAssertTrue(store.isTrusted(deviceId: "device-1"))
        XCTAssertEqual(store.allDevices().count, 1)
        XCTAssertEqual(store.device(for: "device-1")?.deviceName, "Pixel 9")
    }

    func testRevokeRemovesDevice() {
        let url = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = TrustedDevicesStore(fileURL: url)

        store.addDevice(deviceId: "device-1", publicKeyBase64: "abc123==", deviceName: "Pixel 9", deviceType: .androidPhone)
        XCTAssertTrue(store.isTrusted(deviceId: "device-1"))

        store.revoke(deviceId: "device-1")
        XCTAssertFalse(store.isTrusted(deviceId: "device-1"))
        XCTAssertTrue(store.allDevices().isEmpty)
    }

    func testPersistenceSurvivesReload() {
        let url = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let store = TrustedDevicesStore(fileURL: url)
            store.addDevice(deviceId: "device-1", publicKeyBase64: "abc123==", deviceName: "Pixel 9", deviceType: .androidPhone)
        }

        let reloaded = TrustedDevicesStore(fileURL: url)
        XCTAssertTrue(reloaded.isTrusted(deviceId: "device-1"))
        XCTAssertEqual(reloaded.device(for: "device-1")?.deviceName, "Pixel 9")
    }

    func testMultipleDevicesSupported() {
        let url = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = TrustedDevicesStore(fileURL: url)

        store.addDevice(deviceId: "phone-1", publicKeyBase64: "aaa==", deviceName: "Phone", deviceType: .androidPhone)
        store.addDevice(deviceId: "tablet-1", publicKeyBase64: "bbb==", deviceName: "Tablet", deviceType: .androidTablet)

        XCTAssertEqual(store.allDevices().count, 2)
        XCTAssertTrue(store.isTrusted(deviceId: "phone-1"))
        XCTAssertTrue(store.isTrusted(deviceId: "tablet-1"))
    }
}
