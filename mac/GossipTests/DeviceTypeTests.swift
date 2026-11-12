import XCTest
@testable import Gossip

final class DeviceTypeTests: XCTestCase {
    func testDesktopTypesDecode() {
        XCTAssertEqual(DeviceType(rawValue: "windows"), .windows)
        XCTAssertEqual(DeviceType(rawValue: "linux"), .linux)
        XCTAssertNil(DeviceType(rawValue: "plan9"))
    }

    func testOnlyPhonesAndTabletsAreAndroid() {
        XCTAssertTrue(DeviceType.androidPhone.isAndroid)
        XCTAssertTrue(DeviceType.androidTablet.isAndroid)
        XCTAssertFalse(DeviceType.mac.isAndroid)
        XCTAssertFalse(DeviceType.windows.isAndroid)
        XCTAssertFalse(DeviceType.linux.isAndroid)
    }
}
