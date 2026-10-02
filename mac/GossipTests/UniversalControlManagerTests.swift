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

    // MARK: Navigation shortcuts

    func testCommandNumberShortcutsSendDeviceActionsInsteadOfKeys() {
        makeReady("A", "B")
        pushIntoA()
        let before = sessions["A"]!.frames.count
        let cmd: ControlModifierFlags = [.command]
        for (code, action) in [(18, ControlAction.home), (19, .appSwitch), (20, .notifications), (33, .back)] as [(UInt16, ControlAction)] {
            XCTAssertEqual(manager.handle(.key(keyCode: code, down: true, isRepeat: false, characters: "1", flags: cmd)), .swallow)
            XCTAssertEqual(manager.handle(.key(keyCode: code, down: false, isRepeat: false, characters: "1", flags: cmd)), .swallow)
            XCTAssertEqual(sessions["A"]!.frames.filter { $0 == .action(action) }.count, 1, "\(action) sent once for press + release")
        }
        _ = manager.handle(.key(keyCode: 18, down: true, isRepeat: true, characters: "1", flags: cmd))
        XCTAssertEqual(sessions["A"]!.frames.filter { $0 == .action(.home) }.count, 1, "auto-repeat is ignored")
        let after = Array(sessions["A"]!.frames.dropFirst(before))
        XCTAssertFalse(after.contains { if case .key = $0 { return true }; if case .text = $0 { return true }; return false }, "the key itself isn't forwarded")
    }

    func testShortcutsOnlyApplyWhileTheCursorIsOnTheDeviceAndForPlainCommand() {
        makeReady("A", "B")
        let cmd: ControlModifierFlags = [.command]
        XCTAssertEqual(manager.handle(.key(keyCode: 18, down: true, isRepeat: false, characters: "1", flags: cmd)), .pass, "cursor is on the Mac")
        XCTAssertTrue(sessions["A"]!.frames.isEmpty)
        pushIntoA()
        _ = manager.handle(.key(keyCode: 18, down: true, isRepeat: false, characters: "1", flags: [.command, .shift]))
        XCTAssertFalse(sessions["A"]!.frames.contains(.action(.home)), "⌘⇧1 is not the shortcut")
    }

    // MARK: Closed-loop cursor correction

    private var fakeNow: TimeInterval = 100
    private func moveRemote(_ dx: CGFloat, times: Int = 1, advance: TimeInterval = 0.2) {
        for _ in 0..<times {
            fakeNow += advance
            _ = manager.handle(.mouseMoved(delta: CGPoint(x: dx, y: 0), location: .zero))
        }
    }
    private func queries(_ id: String = "A") -> [UInt8] {
        sessions[id]!.frames.compactMap { if case .cursorQuery(let t) = $0 { return t } else { return nil } }
    }
    private func movesSent(_ id: String = "A") -> UInt32 {
        UInt32(sessions[id]!.frames.filter { if case .mouseMove = $0 { return true } else { return false } }.count)
    }

    func testDeviceIsOnlyAskedForItsCursorNearAnExitEdge() {
        manager.clock = { [unowned self] in self.fakeNow }
        makeReady("A", "B")
        pushIntoA()
        XCTAssertTrue(queries().isEmpty, "just entered: the position is exactly known")
        moveRemote(10, times: 6)                       // ~90 points into A: still near the Mac-facing edge
        XCTAssertFalse(queries().isEmpty)
        moveRemote(10, times: 20)                      // on into the middle of A, far from both exit edges
        let inMiddle = queries().count
        moveRemote(1, times: 10)                       // jiggling in the middle asks for nothing
        XCTAssertEqual(queries().count, inMiddle)
    }

    func testReplyCorrectsTheModelSoHandoverHappensAtTheRealEdge() {
        manager.clock = { [unowned self] in self.fakeNow }
        makeReady("A", "B")
        pushIntoA()
        moveRemote(10, times: 10)                      // model: ~150 points in (10 x 1.5 x 10), near the left edge
        guard let token = queries().last else { return XCTFail("no query") }
        // The device says its real cursor is only 30 device pixels (20 points) in: the model had run far ahead.
        sessions["A"]!.onCursorReport?(token, 30, 300, movesSent())
        let leaves = { self.sessions["A"]!.frames.filter { $0 == .leave }.count }
        XCTAssertEqual(leaves(), 0)
        // 20 points from the edge: two moves of -10 (x 1.5 = 15 points each) reach it. Uncorrected, the model
        // (150 points in) would need ten.
        moveRemote(-10, times: 3)
        XCTAssertEqual(leaves(), 1, "handed back to the Mac at the real edge")
    }

    func testStaleOrUnsolicitedRepliesAreIgnored() {
        manager.clock = { [unowned self] in self.fakeNow }
        makeReady("A", "B")
        pushIntoA()
        sessions["A"]!.onCursorReport?(42, 3000, 3000, 0)         // no query outstanding
        moveRemote(10, times: 6)
        guard let token = queries().last else { return XCTFail("no query") }
        sessions["A"]!.onCursorReport?(token &+ 1, 0, 0, movesSent()) // wrong token
        sessions["A"]!.onCursorReport?(token, 0, 0, movesSent() + 500) // a move count we never sent
        moveRemote(-1, times: 2)
        XCTAssertEqual(sessions["A"]!.frames.filter { $0 == .leave }.count, 0, "nothing corrected the model")
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
