import XCTest
@testable import Connect

final class DNDSyncManagerTests: XCTestCase {
    func testParseStateOn() {
        let url = URL(string: "connect://dnd?state=on")!
        XCTAssertEqual(DNDSyncManager.parseState(from: url), true)
    }

    func testParseStateOff() {
        let url = URL(string: "connect://dnd?state=off")!
        XCTAssertEqual(DNDSyncManager.parseState(from: url), false)
    }

    func testParseStateMissingQueryItem() {
        let url = URL(string: "connect://dnd")!
        XCTAssertNil(DNDSyncManager.parseState(from: url))
    }

    func testParseStateInvalidValue() {
        let url = URL(string: "connect://dnd?state=maybe")!
        XCTAssertNil(DNDSyncManager.parseState(from: url))
    }

    func testHandleIncomingURLIgnoresWrongScheme() {
        let manager = DNDSyncManager(transportManager: TransportManager())
        XCTAssertFalse(manager.handleIncomingURL(URL(string: "https://dnd?state=on")!))
    }

    func testHandleIncomingURLIgnoresWrongHost() {
        let manager = DNDSyncManager(transportManager: TransportManager())
        XCTAssertFalse(manager.handleIncomingURL(URL(string: "connect://somethingelse?state=on")!))
    }

    func testHandleIncomingURLAcceptsValidDndURL() {
        let manager = DNDSyncManager(transportManager: TransportManager())
        // Not connected, so reportState's send() will silently fail internally, but the
        // URL itself should still be recognized/parsed as a valid dnd URL.
        XCTAssertTrue(manager.handleIncomingURL(URL(string: "connect://dnd?state=on")!))
    }
}
