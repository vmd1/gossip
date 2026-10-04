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

    func testSecretAndTransientPasteboardTypesAreNeverSynced() {
        XCTAssertTrue(ClipboardSyncManager.isSensitive(types: [.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")]))
        XCTAssertTrue(ClipboardSyncManager.isSensitive(types: [NSPasteboard.PasteboardType("org.nspasteboard.TransientType")]))
        XCTAssertTrue(ClipboardSyncManager.isSensitive(types: [NSPasteboard.PasteboardType("com.agilebits.onepassword")]))
        XCTAssertFalse(ClipboardSyncManager.isSensitive(types: [.string, .png]))
        XCTAssertFalse(ClipboardSyncManager.isSensitive(types: nil))
    }

    func testSizeLimits() {
        XCTAssertTrue(ClipboardSyncManager.textAllowed(String(repeating: "a", count: ClipboardSyncManager.maxTextBytes)))
        XCTAssertFalse(ClipboardSyncManager.textAllowed(String(repeating: "a", count: ClipboardSyncManager.maxTextBytes + 1)))
        XCTAssertFalse(ClipboardSyncManager.textAllowed(String(repeating: "€", count: ClipboardSyncManager.maxTextBytes / 2)))
        XCTAssertFalse(ClipboardSyncManager.imageBytesAllowed(0))
        XCTAssertTrue(ClipboardSyncManager.imageBytesAllowed(ClipboardSyncManager.maxImageBytes))
        XCTAssertFalse(ClipboardSyncManager.imageBytesAllowed(ClipboardSyncManager.maxImageBytes + 1))
    }

    func testOnlyRealReasonablyDimensionedImagesAreAccepted() {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = rep.representation(using: .png, properties: [:])!
        XCTAssertTrue(ClipboardSyncManager.isReasonableImage(png))
        XCTAssertFalse(ClipboardSyncManager.isReasonableImage(Data("not an image".utf8)))
        XCTAssertFalse(ClipboardSyncManager.isReasonableImage(Data()))
    }
}
