import XCTest
@testable import Connect

final class ClipboardSyncManagerTests: XCTestCase {
    func testSendsWhenValueDiffersFromLastRemoteSetValue() {
        XCTAssertTrue(ClipboardSyncManager.shouldSend(newValue: "hello", lastRemoteSetValue: "goodbye"))
    }

    func testSendsWhenThereIsNoLastRemoteSetValueYet() {
        XCTAssertTrue(ClipboardSyncManager.shouldSend(newValue: "hello", lastRemoteSetValue: nil))
    }

    func testSuppressesSendWhenValueMatchesLastRemoteSetValue() {
        XCTAssertFalse(ClipboardSyncManager.shouldSend(newValue: "hello", lastRemoteSetValue: "hello"))
    }
}
