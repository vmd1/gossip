import XCTest
@testable import Gossip

final class PointerRouterTests: XCTestCase {
    private let mac = "MAC-1"
    private var layout: ControlLayout!
    private let size = CGSize(width: 800, height: 500)

    override func setUp() {
        layout = ControlLayout(macDisplays: [mac: CGRect(x: 0, y: 0, width: 1440, height: 900)])
        layout.place(deviceId: "A", size: size, proposedOrigin: CGPoint(x: 1440, y: 100))    // right of the Mac
        layout.place(deviceId: "B", size: size, proposedOrigin: CGPoint(x: 2240, y: 100))    // right of A
    }

    private func router(ready: Set<String> = ["A", "B"]) -> PointerRouter {
        var r = PointerRouter(layout: layout, pushThreshold: 30)
        r.readyDevices = ready
        return r
    }

    /// Pushes the Mac cursor against the right edge at y until it crosses.
    private func pushRight(_ r: inout PointerRouter, y: Double = 300, steps: Int = 10) -> [PointerRouter.Action] {
        var all: [PointerRouter.Action] = []
        for _ in 0..<steps { all += r.macMoved(delta: CGPoint(x: 5, y: 0), location: CGPoint(x: 1439.5, y: y)) }
        return all
    }

    func testEnteringNeedsASustainedPush() {
        var r = router()
        XCTAssertTrue(r.macMoved(delta: CGPoint(x: 5, y: 0), location: CGPoint(x: 1439.5, y: 300)).isEmpty, "a touch is not enough")
        XCTAssertEqual(r.state, .local)
        // Moving away resets the accumulated push.
        _ = r.macMoved(delta: CGPoint(x: -5, y: 0), location: CGPoint(x: 1300, y: 300))
        for _ in 0..<5 { _ = r.macMoved(delta: CGPoint(x: 5, y: 0), location: CGPoint(x: 1439.5, y: 300)) }
        XCTAssertEqual(r.state, .local, "25 points total, below the 30 threshold")
        let actions = pushRight(&r)
        XCTAssertEqual(actions.count, 1)
        guard case .enter(let id, let edge, let fraction)? = actions.first else { return XCTFail("\(actions)") }
        XCTAssertEqual(id, "A"); XCTAssertEqual(edge, .left)
        XCTAssertEqual(fraction, (300.0 - 100) / 500, accuracy: 0.001, "entry is aligned with where the cursor left")
        XCTAssertEqual(r.state.remoteDeviceId, "A")
    }

    func testNoCrossingWhereNothingIsPlacedOrDeviceNotReady() {
        var r = router()
        XCTAssertTrue(pushRight(&r, y: 50).isEmpty, "above the tablet")
        XCTAssertEqual(r.state, .local)
        var notReady = router(ready: [])
        XCTAssertTrue(pushRight(&notReady).isEmpty)
        XCTAssertEqual(notReady.state, .local)
        var left = router()
        for _ in 0..<20 { XCTAssertTrue(left.macMoved(delta: CGPoint(x: -5, y: 0), location: CGPoint(x: 0.5, y: 300)).isEmpty) }
    }

    func testMovesAreForwardedAndClampedInsideTheRectangle() {
        var r = router()
        _ = pushRight(&r)
        let actions = r.remoteMoved(delta: CGPoint(x: 10, y: 20))
        XCTAssertEqual(actions, [.move(deviceId: "A", dx: 10, dy: 20)])
        // A wall: no neighbour above A (y=100 is its top) -> stays remote, full delta still sent.
        let wall = r.remoteMoved(delta: CGPoint(x: 0, y: -1000))
        XCTAssertEqual(wall, [.move(deviceId: "A", dx: 0, dy: -1000)])
        XCTAssertEqual(r.state.remoteDeviceId, "A")
        if case .remote(_, let p) = r.state { XCTAssertEqual(p.y, 100, accuracy: 0.001) }
    }

    func testHandoverAtoBThenBackToMac() {
        var r = router()
        _ = pushRight(&r)                                  // Mac -> A at y 300
        let toB = r.remoteMoved(delta: CGPoint(x: 900, y: 0))     // run off A's right edge into B
        XCTAssertEqual(toB.count, 3)
        XCTAssertEqual(toB[1], .leave(deviceId: "A"))
        guard case .enter("B", let edge, _) = toB[2] else { return XCTFail("\(toB)") }
        XCTAssertEqual(edge, .left)
        XCTAssertEqual(r.state.remoteDeviceId, "B")

        // Now go back left through B and A to the Mac.
        let toA = r.remoteMoved(delta: CGPoint(x: -900, y: 0))
        XCTAssertEqual(toA[1], .leave(deviceId: "B"))
        XCTAssertEqual(r.state.remoteDeviceId, "A")
        let home = r.remoteMoved(delta: CGPoint(x: -900, y: 0))
        XCTAssertEqual(home[1], .leave(deviceId: "A"))
        guard case .warpMacCursor(let p)? = home.last else { return XCTFail("\(home)") }
        XCTAssertEqual(p.x, 1438, accuracy: 0.01, "lands just inside the Mac's right edge")
        XCTAssertEqual(r.state, .local)
    }

    func testHandoverToAnUnavailableDeviceIsAWall() {
        var r = router(ready: ["A"])
        _ = pushRight(&r)
        let actions = r.remoteMoved(delta: CGPoint(x: 900, y: 0))
        XCTAssertEqual(actions, [.move(deviceId: "A", dx: 900, dy: 0)])
        XCTAssertEqual(r.state.remoteDeviceId, "A")
    }

    func testLosingTheSessionReturnsToTheMacWithoutTalkingToTheDevice() {
        var r = router()
        _ = pushRight(&r)
        let actions = r.deviceBecameUnavailable("A")
        XCTAssertEqual(actions.count, 1)
        guard case .warpMacCursor? = actions.first else { return XCTFail("\(actions)") }
        XCTAssertEqual(r.state, .local)
        XCTAssertTrue(r.deviceBecameUnavailable("B").isEmpty, "unrelated device: nothing to do")
    }

    func testForceReturnAndShelvingTheActiveDevice() {
        var r = router()
        _ = pushRight(&r)
        let actions = r.forceReturn(nearestTo: CGPoint(x: 700, y: 400))
        XCTAssertEqual(actions, [.leave(deviceId: "A"), .warpMacCursor(CGPoint(x: 700, y: 400))])
        XCTAssertTrue(r.forceReturn(nearestTo: nil).isEmpty, "idempotent")

        var r2 = router()
        _ = pushRight(&r2)
        var shelved = layout!
        _ = shelved.remove(deviceId: "A")
        let after = r2.setLayout(shelved)
        XCTAssertEqual(r2.state, .local)
        XCTAssertTrue(after.contains(.leave(deviceId: "A")))
    }

    func testVerticalCrossingAndTwoDisplays() {
        var l = ControlLayout(macDisplays: ["M1": CGRect(x: 0, y: 0, width: 1000, height: 800), "M2": CGRect(x: 1000, y: 0, width: 1000, height: 800)])
        l.place(deviceId: "P", size: CGSize(width: 400, height: 600), proposedOrigin: CGPoint(x: 600, y: 800))   // below both, touching M1 bottom
        var r = PointerRouter(layout: l, pushThreshold: 10)
        r.readyDevices = ["P"]
        // Between displays the Mac cursor passes normally (no neighbour device on that edge).
        XCTAssertTrue(r.macMoved(delta: CGPoint(x: 5, y: 0), location: CGPoint(x: 999.5, y: 400)).isEmpty)
        var actions: [PointerRouter.Action] = []
        for _ in 0..<5 { actions += r.macMoved(delta: CGPoint(x: 0, y: 5), location: CGPoint(x: 700, y: 799.5)) }
        guard case .enter("P", .top, _)? = actions.first else { return XCTFail("\(actions)") }
    }
}
