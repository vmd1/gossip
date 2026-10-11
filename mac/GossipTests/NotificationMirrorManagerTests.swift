import XCTest
@testable import Gossip
import GossipCoreKit

final class NotificationMirrorManagerTests: XCTestCase {
    func makeManager() -> NotificationMirrorManager {
        NotificationMirrorManager(transportManager: TransportManager())
    }

    func testLocalIdentifierRoundTrip() {
        let manager = makeManager()
        let local = manager.localIdentifier(for: "android-notif-42", sourceDeviceId: "device-abc")
        XCTAssertTrue(local.hasSuffix("android-notif-42"))
        let decoded = manager.decodeLocalIdentifier(local)
        XCTAssertEqual(decoded?.sourceDeviceId, "device-abc")
        XCTAssertEqual(decoded?.androidId, "android-notif-42")
    }

    func testDecodeLocalIdentifierReturnsNilForUnrelatedIdentifier() {
        let manager = makeManager()
        XCTAssertNil(manager.decodeLocalIdentifier("some.other.identifier"))
    }

    func testDecodeNotificationPostedPayload() throws {
        let manager = makeManager()
        let payload: JSONValue = .object([
            "id": .string("42"),
            "appPackage": .string("com.whatsapp"),
            "appName": .string("WhatsApp"),
            "title": .string("Jane Doe"),
            "body": .string("Running 5 min late"),
            "hasReplyAction": .bool(true),
            "timestamp": .number(1_732_300_000_000)
        ])

        let decoded = try manager.decode(NotificationPostedPayload.self, from: payload)

        XCTAssertEqual(decoded.id, "42")
        XCTAssertEqual(decoded.appPackage, "com.whatsapp")
        XCTAssertEqual(decoded.appName, "WhatsApp")
        XCTAssertEqual(decoded.title, "Jane Doe")
        XCTAssertEqual(decoded.body, "Running 5 min late")
        XCTAssertNil(decoded.iconBase64)
        XCTAssertTrue(decoded.hasReplyAction)
    }

    func testDecodeNotificationRemovedPayload() throws {
        let manager = makeManager()
        let payload: JSONValue = .object(["id": .string("42")])
        let decoded = try manager.decode(NotificationRemovedPayload.self, from: payload)
        XCTAssertEqual(decoded.id, "42")
    }

    func testNotificationReplyPayloadEncodesExpectedFields() throws {
        // The payload is built by the core, and the receiver's `ReplyGuard` accepts each attempt once.
        let json = GossipCoreKit.notificationReplyPayload(notificationId: "42", text: "On my way", attemptId: "attempt-1")
        let guardLogic = GossipCoreKit.ReplyGuard()
        let accepted = try guardLogic.accept(payloadJson: json)
        XCTAssertEqual(accepted?.notificationId, "42")
        XCTAssertEqual(accepted?.text, "On my way")
        XCTAssertNil(try guardLogic.accept(payloadJson: json), "the same attempt is acted on once")
    }

    func testReplyCategoryUsesTextInputAction() {
        XCTAssertEqual(NotificationMirrorManager.replyCategoryIdentifier, "dev.vmd1.gossip.notification.reply")
        XCTAssertEqual(NotificationMirrorManager.replyActionIdentifier, "dev.vmd1.gossip.notification.replyAction")
    }
}
