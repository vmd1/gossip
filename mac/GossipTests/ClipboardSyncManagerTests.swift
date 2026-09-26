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
}
