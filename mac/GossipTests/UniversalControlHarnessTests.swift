import XCTest
@testable import Gossip

/// The whole stack except the radio: real `DeviceControlSession`s and a real encrypted WebSocket client talking
/// to N in-process fake devices over loopback. Covers parallel warm sessions, A -> B -> Mac handover,
/// failure isolation and reconnect.
final class UniversalControlHarnessTests: XCTestCase {
    private var mesh: FakeMesh!
    private var cursor: FakeCursor!
    private var manager: UniversalControlManager!
    private var devices: [String: FakeControlDevice] = [:]
    private var storeURL: URL!
    private let mac = "MAC-1"

    private let fast = DeviceControlSession.Timing(retryStart: 0.3, negotiationTimeout: 3, backoffInitial: 0.2, backoffMax: 0.5, pingInterval: 0.5, deadAfter: 2)

    override func setUp() {
        mesh = FakeMesh()
        cursor = FakeCursor()
        storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("uch-\(UUID().uuidString).json")
        let store = ControlLayoutStore(fileURL: storeURL)
        var placements: [String: ControlLayout.Placement] = [:]
        for (i, id) in ["A", "B", "C"].enumerated() {
            let d = FakeControlDevice(deviceId: id)
            d.displayInfo = ControlDisplayInfo(width: 1200, height: 750, rotation: 0, backend: 0) // 800x500 pt: matches the placement
            devices[id] = d; mesh.devices[id] = d; mesh.setConnected(id, true)
            placements[id] = ControlLayout.Placement(rect: CGRect(x: 1440 + 800 * Double(i), y: 100, width: 800, height: 500))
        }
        store.savePlacements(placements)
        manager = UniversalControlManager(
            mesh: mesh,
            makeSession: { [unowned self] id in
                let s = DeviceControlSession(deviceId: id, mesh: self.mesh, selfId: "mac", timing: self.fast)
                self.mesh.sessions[id] = s
                return s
            },
            cursor: cursor, store: store,
            macDisplays: { [mac] in [mac: CGRect(x: 0, y: 0, width: 1440, height: 900)] },
            isFeatureEnabled: { true }
        )
        manager.start()
    }

    override func tearDown() {
        manager.stop()
        devices.values.forEach { $0.close() }
        try? FileManager.default.removeItem(at: storeURL)
    }

    private func awaitReady(_ ids: [String], timeout: TimeInterval = 10) -> Bool {
        waitUntil(timeout: timeout) { ids.allSatisfy { self.manager.sessionStates[$0] == .ready } }
    }

    private func push(into _: String = "A") {
        for _ in 0..<10 { _ = manager.handle(.mouseMoved(delta: CGPoint(x: 5, y: 0), location: CGPoint(x: 1439.5, y: 300))) }
    }

    func testParallelWarmSessionsAllCompleteTheEncryptedHandshake() {
        XCTAssertTrue(awaitReady(["A", "B", "C"]), "\(manager.sessionStates) \(mesh.sent)")
        for d in devices.values { XCTAssertTrue(waitUntil { d.helloReceived }, d.deviceId) }
        // Each connection used its own session id and secret.
        XCTAssertEqual(mesh.sent.filter { $0.type == "control.session_start" }.count >= 3, true)
    }

    func testInputReachesTheDeviceThroughTheEncryptedChannelAndHandsOver() {
        XCTAssertTrue(awaitReady(["A", "B", "C"]), "\(manager.sessionStates) \(mesh.sent)")
        push()
        _ = manager.handle(.mouseMoved(delta: CGPoint(x: 20, y: 10), location: .zero))
        XCTAssertTrue(waitUntil { self.devices["A"]!.frames.contains(.mouseMove(dx: 30, dy: 15)) }, "\(devices["A"]!.frames)")
        guard case .enter(.left, _)? = devices["A"]!.frames.dropFirst().first else { return XCTFail("\(devices["A"]!.frames)") }

        _ = manager.handle(.mouseMoved(delta: CGPoint(x: 900, y: 0), location: .zero))     // A -> B
        XCTAssertTrue(waitUntil { self.devices["B"]!.frames.contains { if case .enter(.left, _) = $0 { return true } else { return false } } })
        XCTAssertTrue(waitUntil { self.devices["A"]!.frames.last == .leave })
        _ = manager.handle(.mouseMoved(delta: CGPoint(x: -900, y: 0), location: .zero))    // B -> A
        _ = manager.handle(.mouseMoved(delta: CGPoint(x: -900, y: 0), location: .zero))    // A -> Mac
        XCTAssertEqual(cursor.log.last, "restore")
        XCTAssertTrue(devices["C"]!.frames.allSatisfy { if case .hello = $0 { return true } else if case .ping = $0 { return true } else { return false } }, "C never got input")
    }

    func testOneDeviceFailingDoesNotDisturbTheOthersAndItReconnects() {
        XCTAssertTrue(awaitReady(["A", "B", "C"]), "\(manager.sessionStates) \(mesh.sent)")
        let firstSession = devices["B"]!.helloReceived
        XCTAssertTrue(firstSession)
        devices["B"]!.dropConnection()
        XCTAssertTrue(waitUntil { self.manager.sessionStates["B"] != .ready }, "B notices")
        XCTAssertEqual(manager.sessionStates["A"], .ready)
        XCTAssertEqual(manager.sessionStates["C"], .ready)
        XCTAssertTrue(awaitReady(["B"]), "B reconnects with a fresh session")
        let starts = mesh.sent.filter { $0.type == "control.session_start" && $0.deviceId == "B" }.count
        XCTAssertGreaterThanOrEqual(starts, 2)
        XCTAssertTrue(mesh.sent.contains { $0.type == "control.end" && $0.deviceId == "B" }, "the failed session was ended")
    }

    func testActiveDeviceFailureReturnsThePointerHome() {
        XCTAssertTrue(awaitReady(["A"]))
        push()
        devices["A"]!.dropConnection()
        XCTAssertTrue(waitUntil { self.cursor.log.last == "restore" }, "\(cursor.log)")
        XCTAssertEqual(manager.handle(.mouseMoved(delta: CGPoint(x: 1, y: 1), location: CGPoint(x: 9, y: 9))), .pass)
    }

    func testSilentDeviceTimesOutIntoBackoffAndRecoversWhenItAnswers() {
        manager.stop()                    // setUp already started warm sessions; restart with a mute mesh
        for d in devices.values { d.close() }
        mesh.silent = true
        manager.start()
        XCTAssertTrue(waitUntil(timeout: 8) { if case .backoff = self.manager.sessionStates["A"] ?? .idle { return true } else { return false } })
        mesh.silent = false
        XCTAssertTrue(awaitReady(["A"], timeout: 10))
    }

    func testDeviceSideDisplayInfoUpdatesTheLayout() {
        XCTAssertTrue(awaitReady(["A"]))
        devices["A"]!.sendToMac(.displayInfo(ControlDisplayInfo(width: 1200, height: 2000, rotation: 1, backend: 0)))
        XCTAssertTrue(waitUntil { (self.manager.layout.devices["A"]?.height ?? 0) > 1000 })
    }

    func testDisconnectedDeviceGetsNoSession() {
        mesh.setConnected("C", false)
        manager.reconcile()
        XCTAssertNil(manager.sessionStates["C"])
        XCTAssertFalse(mesh.sent.contains { $0.deviceId == "C" && $0.type == "control.session_start" } && false)
    }
}
