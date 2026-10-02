import XCTest
@testable import Gossip

final class ControlLayoutTests: XCTestCase {
    private let mac = "MAC-1"
    private func layout() -> ControlLayout {
        ControlLayout(macDisplays: [mac: CGRect(x: 0, y: 0, width: 1440, height: 900)])
    }
    private let tabletSize = CGSize(width: 800, height: 500)

    func testPlacesAgainstEdgeAndSnapsWithinDistance() {
        var l = layout()
        // 10 points off the right edge snaps flush; the top edge is 20 away so it aligns flush too.
        let origin = l.place(deviceId: "t", size: tabletSize, proposedOrigin: CGPoint(x: 1450, y: 20))
        XCTAssertEqual(origin, CGPoint(x: 1440, y: 0))
        var l2 = layout()
        // 40 points below the top edge is beyond snap distance, so only the touching axis snaps.
        XCTAssertEqual(l2.place(deviceId: "u", size: tabletSize, proposedOrigin: CGPoint(x: 1450, y: 40)), CGPoint(x: 1440, y: 40))
        XCTAssertTrue(l.isPlaced("t"))
    }

    func testRejectsFloatingAndOverlappingSpots() {
        var l = layout()
        XCTAssertNil(l.place(deviceId: "t", size: tabletSize, proposedOrigin: CGPoint(x: 2000, y: 0)), "too far to touch anything")
        XCTAssertFalse(l.isPlaced("t"))
        XCTAssertNil(l.place(deviceId: "t", size: tabletSize, proposedOrigin: CGPoint(x: 600, y: 100)), "overlaps the Mac")
    }

    func testSnapsFlushAlongSharedEdge() {
        var l = layout()
        let o = l.place(deviceId: "t", size: tabletSize, proposedOrigin: CGPoint(x: 1441, y: 12))
        // Top edges are 12 apart: snaps flush with the Mac's top as well as touching its right side.
        XCTAssertEqual(o, CGPoint(x: 1440, y: 0))
    }

    func testDeviceMayAttachToAnotherDeviceAndOverlapIsRejected() {
        var l = layout()
        l.place(deviceId: "a", size: tabletSize, proposedOrigin: CGPoint(x: 1440, y: 0))
        let b = l.place(deviceId: "b", size: CGSize(width: 400, height: 700), proposedOrigin: CGPoint(x: 2243, y: 100))
        XCTAssertEqual(b?.x, 2240)
        XCTAssertNil(l.place(deviceId: "c", size: tabletSize, proposedOrigin: CGPoint(x: 1500, y: 100)), "overlaps a")
    }

    func testMovingADeviceIgnoresItsOwnOldPlacement() {
        var l = layout()
        l.place(deviceId: "a", size: tabletSize, proposedOrigin: CGPoint(x: 1440, y: 0))
        XCTAssertNotNil(l.place(deviceId: "a", size: tabletSize, proposedOrigin: CGPoint(x: 1440, y: 100)), "sliding along the edge")
        XCTAssertEqual(l.devices["a"]?.y, 100)
    }

    func testNeighborLookupUsesLayoutAlignment() {
        var l = layout()
        l.place(deviceId: "t", size: tabletSize, proposedOrigin: CGPoint(x: 1440, y: 200))
        XCTAssertEqual(l.neighbor(of: .mac(mac), through: .right, along: 300), .device("t"))
        XCTAssertNil(l.neighbor(of: .mac(mac), through: .right, along: 100), "above the tablet")
        XCTAssertNil(l.neighbor(of: .mac(mac), through: .left, along: 300))
        XCTAssertEqual(l.neighbor(of: .device("t"), through: .left, along: 300), .mac(mac))
        XCTAssertEqual(l.edgeFraction(of: .device("t"), edge: .left, along: 450) ?? -1, 0.5, accuracy: 0.0001)
    }

    func testRemovingAMiddleDeviceShelvesTheOnesOnlyReachableThroughIt() {
        var l = layout()
        l.place(deviceId: "a", size: tabletSize, proposedOrigin: CGPoint(x: 1440, y: 0))
        l.place(deviceId: "b", size: tabletSize, proposedOrigin: CGPoint(x: 2240, y: 0))
        let removed = Set(l.remove(deviceId: "a"))
        XCTAssertEqual(removed, ["a", "b"])
        XCTAssertTrue(l.devices.isEmpty)
    }

    func testMacDisplayChangeShelvesDevicesThatNoLongerTouch() {
        var l = layout()
        l.place(deviceId: "a", size: tabletSize, proposedOrigin: CGPoint(x: 1440, y: 0))
        let dropped = l.setMacDisplays([mac: CGRect(x: 0, y: 0, width: 1000, height: 900)])
        XCTAssertEqual(dropped, ["a"])
    }

    func testResizeKeepsTopLeftAndShelvesOnOverlap() {
        var l = layout()
        l.place(deviceId: "a", size: tabletSize, proposedOrigin: CGPoint(x: 1440, y: 0))
        l.place(deviceId: "b", size: tabletSize, proposedOrigin: CGPoint(x: 2240, y: 0))
        // a shrinks, so b (placed against a's old right edge) no longer touches anything.
        XCTAssertEqual(l.resize(deviceId: "a", to: CGSize(width: 500, height: 800)), ["b"])
        XCTAssertEqual(l.devices["a"]?.width, 500)
        XCTAssertEqual(l.devices["a"]?.x, 1440)
    }

    func testPersistenceRoundTrip() throws {
        var l = layout()
        l.place(deviceId: "a", size: tabletSize, proposedOrigin: CGPoint(x: 1440, y: 40))
        let decoded = try XCTUnwrap(ControlLayout.decodeDevices(l.encodedDevices()))
        XCTAssertEqual(decoded, l.devices)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("layout-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = ControlLayoutStore(fileURL: file)
        store.savePlacements(l.devices)
        store.saveSizes(["a": CGSize(width: 2000, height: 1200)])
        let reopened = ControlLayoutStore(fileURL: file)
        XCTAssertEqual(reopened.loadPlacements(), l.devices)
        XCTAssertEqual(reopened.loadSizes()["a"], CGSize(width: 2000, height: 1200))
    }

    // MARK: Placement forgiveness and resize

    func testCaptureDistanceAttachesANearMissInsteadOfRejecting() {
        var l = layout()
        // 150 points off the right edge: rejected by default, attached flush when capture is allowed.
        XCTAssertNil(layout().resolveDrop(deviceId: "t", size: tabletSize, proposedOrigin: CGPoint(x: 1590, y: 100)))
        let o = l.place(deviceId: "t", size: tabletSize, proposedOrigin: CGPoint(x: 1590, y: 100), captureDistance: 200)
        XCTAssertEqual(o, CGPoint(x: 1440, y: 100))
        XCTAssertNil(layout().resolveDrop(deviceId: "t", size: tabletSize, proposedOrigin: CGPoint(x: 3000, y: 100), captureDistance: 200), "too far even for capture")
    }

    func testLargerSnapDistanceSnapsFromFurther() {
        var l = layout()
        XCTAssertEqual(l.place(deviceId: "t", size: tabletSize, proposedOrigin: CGPoint(x: 1480, y: 300), snapDistance: 60), CGPoint(x: 1440, y: 300))
    }

    func testResizeToPortraitKeepsDeviceAttachedOnEachSide() {
        // Placed with the default landscape size, then the phone reports its real portrait size.
        let portrait = CGSize(width: 400, height: 900)
        for (origin, name) in [(CGPoint(x: 1440, y: 0), "right"), (CGPoint(x: -800, y: 0), "left"),
                               (CGPoint(x: 100, y: 900), "bottom"), (CGPoint(x: 100, y: -500), "top")] {
            var l = layout()
            XCTAssertNotNil(l.place(deviceId: "p", size: tabletSize, proposedOrigin: origin), name)
            let shelved = l.resize(deviceId: "p", to: portrait)
            XCTAssertTrue(shelved.isEmpty, "\(name): shelved \(shelved)")
            XCTAssertTrue(l.isPlaced("p"), name)
            XCTAssertEqual(l.devices["p"]?.rect.size, portrait, name)
        }
    }

    func testResizeToSameSizeIsANoOp() {
        var l = layout()
        l.place(deviceId: "p", size: tabletSize, proposedOrigin: CGPoint(x: 1440, y: 0))
        let before = l
        XCTAssertTrue(l.resize(deviceId: "p", to: tabletSize).isEmpty)
        XCTAssertEqual(l, before)
    }

    func testParseDisplaySize() {
        XCTAssertEqual(UniversalControlManager.parseDisplaySize(.object(["width": .number(1080), "height": .number(2400)]))?.height, 2400)
        XCTAssertNil(UniversalControlManager.parseDisplaySize(.object(["width": .number(0), "height": .number(2400)])))
        XCTAssertNil(UniversalControlManager.parseDisplaySize(.object(["width": .number(99999), "height": .number(10)])))
        XCTAssertNil(UniversalControlManager.parseDisplaySize(.object([:])))
    }
}

final class HIDKeyTableTests: XCTestCase {
    func testCommonKeys() {
        XCTAssertEqual(HIDKeyTable.usageForMacKeyCode[0], 0x04)    // A
        XCTAssertEqual(HIDKeyTable.usageForMacKeyCode[6], 0x1D)    // Z
        XCTAssertEqual(HIDKeyTable.usageForMacKeyCode[18], 0x1E)   // 1
        XCTAssertEqual(HIDKeyTable.usageForMacKeyCode[29], 0x27)   // 0
        XCTAssertEqual(HIDKeyTable.usageForMacKeyCode[36], 0x28)   // Return
        XCTAssertEqual(HIDKeyTable.usageForMacKeyCode[51], 0x2A)   // Backspace
        XCTAssertEqual(HIDKeyTable.usageForMacKeyCode[49], 0x2C)   // Space
        XCTAssertEqual(HIDKeyTable.usageForMacKeyCode[122], 0x3A)  // F1
        XCTAssertEqual(HIDKeyTable.usageForMacKeyCode[111], 0x45)  // F12
        XCTAssertEqual(HIDKeyTable.usageForMacKeyCode[126], 0x52)  // Up
        XCTAssertEqual(HIDKeyTable.usageForMacKeyCode[117], 0x4C)  // Forward delete
    }

    func testNoTwoKeysShareAUsageExceptTheDocumentedAlias() {
        var seen: [UInt16: UInt16] = [:]
        for (code, usage) in HIDKeyTable.usageForMacKeyCode {
            if let other = seen[usage] { XCTFail("keycodes \(other) and \(code) both map to \(usage)") }
            seen[usage] = code
        }
    }

    func testCommandMapping() {
        XCTAssertEqual(HIDKeyTable.usage(forMacKeyCode: 55, command: .control), 0xE0)
        XCTAssertEqual(HIDKeyTable.usage(forMacKeyCode: 55, command: .meta), 0xE3)
        XCTAssertEqual(HIDKeyTable.usage(forMacKeyCode: 54, command: .control), 0xE4)
        XCTAssertEqual(HIDKeyTable.usage(forMacKeyCode: 54, command: .meta), 0xE7)
        XCTAssertEqual(HIDKeyTable.modifierByte(shift: true, control: false, option: true, command: true, mapping: .control), 0x02 | 0x04 | 0x01)
        XCTAssertEqual(HIDKeyTable.modifierByte(shift: false, control: false, option: false, command: true, mapping: .meta), 0x08)
        XCTAssertEqual(HIDKeyTable.modifierBit(forMacKeyCode: 56, command: .control), 0x02)
    }

    func testModifierDownFromDeviceDependentBits() {
        XCTAssertEqual(ControlEventTap.modifierIsDown(keyCode: 56, rawFlags: 0x2), true)
        XCTAssertEqual(ControlEventTap.modifierIsDown(keyCode: 56, rawFlags: 0x0), false)
        XCTAssertEqual(ControlEventTap.modifierIsDown(keyCode: 60, rawFlags: 0x2), false, "left shift down, right shift event")
        XCTAssertEqual(ControlEventTap.modifierIsDown(keyCode: 62, rawFlags: 0x2000), true)
        XCTAssertNil(ControlEventTap.modifierIsDown(keyCode: 0, rawFlags: 0))
    }
}
