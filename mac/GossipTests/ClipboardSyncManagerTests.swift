import XCTest
@testable import Gossip
import GossipCoreKit

final class ClipboardSyncManagerTests: XCTestCase {
    func testALocalCopyIsPublishedOnceAndEchoesAreSuppressed() throws {
        let guardLogic = GossipCoreKit.ClipboardGuard()
        XCTAssertNotNil(guardLogic.outgoingText(me: "me", text: "hello", sensitive: false), "a genuine local copy")
        XCTAssertNil(guardLogic.outgoingText(me: "me", text: "hello", sensitive: false), "the same value is not published again")
        let incoming = try guardLogic.incomingText(payloadJson: #"{"text":"from-peer","sourceDeviceId":"peer"}"#)
        XCTAssertEqual(incoming, "from-peer")
        XCTAssertNil(guardLogic.outgoingText(me: "me", text: "from-peer", sensitive: false), "our own write echoed back by the next poll")
        XCTAssertNotNil(guardLogic.outgoingText(me: "me", text: "new local", sensitive: false))
        XCTAssertNil(guardLogic.outgoingText(me: "me", text: "secret", sensitive: true), "sensitive content is never published")
    }

    func testImagesAreSuppressedLikeText() {
        let guardLogic = GossipCoreKit.ClipboardGuard()
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = rep.representation(using: .png, properties: [:])!
        XCTAssertNotNil(guardLogic.outgoingImage(me: "me", png: png, sensitive: false))
        XCTAssertNil(guardLogic.outgoingImage(me: "me", png: png, sensitive: false), "the same image is not sent again")
        XCTAssertNil(guardLogic.outgoingImage(me: "me", png: png, sensitive: true))
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
