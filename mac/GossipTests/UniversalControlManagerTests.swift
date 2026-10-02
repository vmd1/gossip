import XCTest
@testable import Gossip

/// Manager behaviour against fake sessions (fast, deterministic).
final class UniversalControlManagerTests: XCTestCase {
    private let mac = "MAC-1"
    private var cursor: FakeCursor!
    private var sessions: [String: FakeControlSession] = [:]
    private var connected: Set<String> = ["A", "B"]
    private var manager: UniversalControlManager!
    private var typing = ControlTypingMode.characters
    private var mapping = HIDKeyTable.CommandMapping.control
    private var storeURL: URL!

    override func setUp() {
        cursor = FakeCursor()
        storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("uc-\(UUID().uuidString).json")
        let store = ControlLayoutStore(fileURL: storeURL)
        store.savePlacements([
            "A": ControlLayout.Placement(rect: CGRect(x: 1440, y: 100, width: 800, height: 500)),
            "B": ControlLayout.Placement(rect: CGRect(x: 2240, y: 100, width: 800, height: 500)),
        ])
        manager = UniversalControlManager(
            mesh: StubMesh(connected: { [unowned self] in self.connected }),
            makeSession: { [unowned self] id in let s = FakeControlSession(deviceId: id); self.sessions[id] = s; return s },
            cursor: cursor, store: store,
            macDisplays: { [mac] in [mac: CGRect(x: 0, y: 0, width: 1440, height: 900)] },
            isFeatureEnabled: { true },
            commandMapping: { [unowned self] in self.mapping }, typingMode: { [unowned self] in self.typing }
        )
        manager.start()
    }

    override func tearDown() { manager.stop(); try? FileManager.default.removeItem(at: storeURL) }

    private func makeReady(_ ids: String...) {
        for id in ids { sessions[id]?.setState(.ready) }
        _ = waitUntil { ids.allSatisfy { self.manager.sessionStates[$0] == .ready } }
    }

    private func pushIntoA() {
        for _ in 0..<10 { _ = manager.handle(.mouseMoved(delta: CGPoint(x: 5, y: 0), location: CGPoint(x: 1439.5, y: 300))) }
    }

    func testOneSessionPerPlacedConnectedDevice() {
        XCTAssertEqual(Set(sessions.keys), ["A", "B"])
        connected = ["A"]
        manager.reconcile()
        XCTAssertEqual(manager.sessionStates.keys.sorted(), ["A"], "B isn't directly connected, so no session")
        XCTAssertEqual(sessions["B"]?.state, .idle, "and the old one was stopped")
    }

    func testNothingIsCapturedUntilTheDeviceIsReady() {
        for _ in 0..<10 { XCTAssertEqual(manager.handle(.mouseMoved(delta: CGPoint(x: 5, y: 0), location: CGPoint(x: 1439.5, y: 300))), .pass) }
        XCTAssertTrue(sessions["A"]!.frames.isEmpty)
        XCTAssertTrue(cursor.log.isEmpty)
    }

    func testCrossingFreezesTheCursorSwallowsEventsAndForwardsInput() {
        makeReady("A", "B")
        var last = ControlDisposition.pass
        for _ in 0..<10 { last = manager.handle(.mouseMoved(delta: CGPoint(x: 5, y: 0), location: CGPoint(x: 1439.5, y: 300))) }
        XCTAssertEqual(last, .swallow)
        XCTAssertEqual(cursor.log, ["freeze"])
        guard case .enter(let edge, let pos)? = sessions["A"]!.frames.first else { return XCTFail("\(sessions["A"]!.frames)") }
        XCTAssertEqual(edge, .left)
        XCTAssertEqual(Double(pos) / 65535, 0.4, accuracy: 0.001)

        XCTAssertEqual(manager.handle(.mouseMoved(delta: CGPoint(x: 10, y: -4), location: CGPoint(x: 0, y: 0))), .swallow)
        XCTAssertEqual(manager.handle(.button(index: 0, down: true, location: .zero)), .swallow)
        XCTAssertEqual(manager.handle(.scroll(dx: 0, dy: 120)), .swallow)
        let frames = sessions["A"]!.frames
        XCTAssertTrue(frames.contains(.mouseMove(dx: 15, dy: -6)), "10 x 1.5 and -4 x 1.5 device pixels")
        XCTAssertTrue(frames.contains(.buttons(1)))
        XCTAssertTrue(frames.contains(.scroll(dx: 0, dy: 120)))
        XCTAssertTrue(sessions["B"]!.frames.isEmpty, "other devices see nothing")
    }

    func testHandoverAtoBThenHomeRestoresTheCursorOnce() {
        makeReady("A", "B")
        pushIntoA()
        _ = manager.handle(.button(index: 0, down: true, location: .zero))
        _ = manager.handle(.mouseMoved(delta: CGPoint(x: 900, y: 0), location: .zero))   // A -> B
        let a = sessions["A"]!.frames, b = sessions["B"]!.frames
        XCTAssertTrue(a.contains(.buttons(0)), "buttons released before leaving")
        XCTAssertEqual(a.last, .leave)
        guard case .enter(.left, _)? = b.first else { return XCTFail("\(b)") }
        XCTAssertEqual(cursor.log, ["freeze"], "still frozen: the pointer never touched the Mac")

        _ = manager.handle(.mouseMoved(delta: CGPoint(x: -3000, y: 0), location: .zero))  // B -> A -> (second event) Mac
        _ = manager.handle(.mouseMoved(delta: CGPoint(x: -3000, y: 0), location: .zero))
        XCTAssertEqual(cursor.log.first, "freeze")
        XCTAssertTrue(cursor.log.contains("warp(1438,300)"), "\(cursor.log)")
        XCTAssertEqual(cursor.log.last, "restore")
        XCTAssertEqual(manager.handle(.mouseMoved(delta: CGPoint(x: 1, y: 0), location: CGPoint(x: 100, y: 100))), .pass)
    }

    func testHeldKeysAndButtonsAreReleasedWhenLeaving() {
        makeReady("A")
        pushIntoA()
        _ = manager.handle(.modifier(keyCode: 56, down: true))                       // shift
        _ = manager.handle(.key(keyCode: 8, down: true, isRepeat: false, characters: nil, flags: [.command])) // cmd+C as a shortcut
        manager.returnToMac()
        let frames = sessions["A"]!.frames
        XCTAssertTrue(frames.contains(.key(usage: 0xE1, down: false, modifiers: 0)))
        XCTAssertEqual(frames.last, .leave)
        XCTAssertEqual(cursor.log.last, "restore")
    }

    func testTypingUsesCharactersForPlainKeysAndKeyCodesForShortcuts() {
        makeReady("A")
        pushIntoA()
        _ = manager.handle(.key(keyCode: 0, down: true, isRepeat: false, characters: "a", flags: []))
        _ = manager.handle(.key(keyCode: 0, down: false, isRepeat: false, characters: "a", flags: []))
        _ = manager.handle(.key(keyCode: 0, down: true, isRepeat: false, characters: "é", flags: [.option]))
        _ = manager.handle(.modifier(keyCode: 55, down: true))                       // command -> ctrl
        _ = manager.handle(.key(keyCode: 8, down: true, isRepeat: false, characters: "c", flags: [.command]))
        _ = manager.handle(.key(keyCode: 8, down: false, isRepeat: false, characters: "c", flags: [.command]))
        _ = manager.handle(.key(keyCode: 36, down: true, isRepeat: false, characters: "\r", flags: []))
        let frames = sessions["A"]!.frames.dropFirst().filter { if case .mouseMove = $0 { return false } else { return true } }
        XCTAssertEqual(Array(frames), [
            .text("a"), .text("é"),
            .key(usage: 0xE0, down: true, modifiers: 0x01),
            .key(usage: 0x06, down: true, modifiers: 0x01), .key(usage: 0x06, down: false, modifiers: 0x01),
            .key(usage: 0x28, down: true, modifiers: 0x01),
        ])
    }

    func testCommandAsMetaAndKeysOnlyMode() {
        mapping = .meta; typing = .keys
        makeReady("A")
        pushIntoA()
        _ = manager.handle(.modifier(keyCode: 55, down: true))
        _ = manager.handle(.key(keyCode: 0, down: true, isRepeat: false, characters: "a", flags: [.command]))
        XCTAssertEqual(sessions["A"]!.frames.dropFirst().filter { if case .mouseMove = $0 { return false } else { return true } }, [
            .key(usage: 0xE3, down: true, modifiers: 0x08), .key(usage: 0x04, down: true, modifiers: 0x08),
        ])
    }

    func testEscapeHotkeyReturnsFromAnywhere() {
        makeReady("A")
        pushIntoA()
        XCTAssertEqual(manager.handle(.key(keyCode: 53, down: true, isRepeat: false, characters: nil, flags: [.control, .option, .command])), .swallow)
        XCTAssertEqual(cursor.log.last, "restore")
        XCTAssertEqual(manager.handle(.key(keyCode: 53, down: true, isRepeat: false, characters: nil, flags: [.control, .option, .command])), .pass, "now local: not ours")
    }

    func testLosingTheActiveSessionReturnsTheCursor() {
        makeReady("A")
        pushIntoA()
        sessions["A"]!.setState(.backoff(reason: "connection lost"))
        XCTAssertTrue(waitUntil { self.cursor.log.last == "restore" })
        XCTAssertEqual(manager.handle(.mouseMoved(delta: CGPoint(x: 1, y: 1), location: CGPoint(x: 5, y: 5))), .pass)
    }

    func testDisplayInfoResizesTheCardAndIsRemembered() {
        sessions["A"]!.onDisplayInfo?(ControlDisplayInfo(width: 1200, height: 2000, rotation: 1, backend: 0))
        XCTAssertTrue(waitUntil { (self.manager.layout.devices["A"]?.height ?? 0) > 1000 })   // 2000 / 1.5
        XCTAssertEqual(manager.layout.devices["A"]?.width ?? 0, 800, accuracy: 0.01)          // 1200 / 1.5
        XCTAssertEqual(manager.layout.devices["A"]?.height ?? 0, 2000 / 1.5, accuracy: 0.01)
        XCTAssertEqual(ControlLayoutStore(fileURL: storeURL).loadSizes()["A"], CGSize(width: 1200, height: 2000))
    }

    func testShelvingStopsTheSessionAndPlacingRestartsIt() {
        manager.shelve(deviceId: "B")
        XCTAssertEqual(sessions["B"]?.state, .idle)
        XCTAssertNil(manager.sessionStates["B"])
        XCTAssertFalse(manager.layout.isPlaced("B"))
        XCTAssertTrue(manager.place(deviceId: "B", origin: CGPoint(x: 2245, y: 100)))
        XCTAssertNotNil(manager.sessionStates["B"])
        XCTAssertEqual(manager.layout.devices["B"]?.x ?? 0, 2240, accuracy: 0.01, "snapped")
    }

    func testMessagePrefixAndFeatureToggle() {
        XCTAssertEqual(FeatureSettings.feature(forMessageType: "control.ready"), .universalControl)
        var enabled = true
        let m = UniversalControlManager(
            mesh: StubMesh(connected: { ["A"] }), makeSession: { FakeControlSession(deviceId: $0) }, cursor: FakeCursor(),
            store: ControlLayoutStore(fileURL: storeURL), macDisplays: { [self.mac: CGRect(x: 0, y: 0, width: 1440, height: 900)] },
            isFeatureEnabled: { enabled })
        enabled = false
        m.start()
        XCTAssertTrue(m.sessionStates.isEmpty, "feature off: no sessions")
        m.stop()
    }
}

final class StubMesh: ControlMesh {
    let connected: () -> Set<String>
    init(connected: @escaping () -> Set<String>) { self.connected = connected }
    func isDirectlyConnected(_ deviceId: String) -> Bool { connected().contains(deviceId) }
    func host(for deviceId: String) -> String? { "127.0.0.1" }
    func sendControl(type: String, to deviceId: String, payload: [String: JSONValue]) {}
}
