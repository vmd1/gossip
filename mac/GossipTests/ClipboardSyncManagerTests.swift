import XCTest
@testable import Gossip

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

    func testSuppressesSendWhenValueMatchesLastSentValue() {
        // Regression test for #29: without checking lastSentValue too, the periodic resync
        // would re-broadcast a locally-originated pasteboard value forever, since
        // lastRemoteSetValue (only set on receiving a peer's update) never matches it.
        XCTAssertFalse(ClipboardSyncManager.shouldSend(newValue: "hello", lastRemoteSetValue: nil, lastSentValue: "hello"))
    }

    func testSendsWhenValueDiffersFromBothLastRemoteSetAndLastSentValue() {
        XCTAssertTrue(ClipboardSyncManager.shouldSend(newValue: "hello", lastRemoteSetValue: "goodbye", lastSentValue: "earlier"))
    }

    func testSendsImageWhenDataDiffersFromLastRemoteSetImageData() {
        let a = Data([0x01, 0x02])
        let b = Data([0x03, 0x04])
        XCTAssertTrue(ClipboardSyncManager.shouldSend(newImageData: a, lastRemoteSetImageData: b))
    }

    func testSendsImageWhenThereIsNoLastRemoteSetImageDataYet() {
        XCTAssertTrue(ClipboardSyncManager.shouldSend(newImageData: Data([0x01]), lastRemoteSetImageData: nil))
    }

    func testSuppressesImageSendWhenDataMatchesLastRemoteSetImageData() {
        let data = Data([0x01, 0x02, 0x03])
        XCTAssertFalse(ClipboardSyncManager.shouldSend(newImageData: data, lastRemoteSetImageData: data))
    }

    func testSuppressesImageSendWhenDataMatchesLastSentImageData() {
        let data = Data([0x01, 0x02, 0x03])
        XCTAssertFalse(ClipboardSyncManager.shouldSend(newImageData: data, lastRemoteSetImageData: nil, lastSentImageData: data))
    }

    func testSendsImageWhenDataDiffersFromBothLastRemoteSetAndLastSentImageData() {
        XCTAssertTrue(ClipboardSyncManager.shouldSend(newImageData: Data([0x09]), lastRemoteSetImageData: Data([0x01]), lastSentImageData: Data([0x02])))
    }
}
