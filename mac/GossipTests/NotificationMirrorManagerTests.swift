import XCTest
@testable import Gossip

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
        let reply = NotificationReplyPayload(id: "42", text: "On my way", attemptId: "attempt-1")
        let data = try JSONEncoder().encode(reply)
        let decoded = try JSONDecoder().decode(NotificationReplyPayload.self, from: data)
        XCTAssertEqual(decoded.id, "42")
        XCTAssertEqual(decoded.text, "On my way")
        XCTAssertEqual(decoded.attemptId, "attempt-1")
    }

    func testReplyCategoryUsesTextInputAction() {
        XCTAssertEqual(NotificationMirrorManager.replyCategoryIdentifier, "dev.vmd1.gossip.notification.reply")
        XCTAssertEqual(NotificationMirrorManager.replyActionIdentifier, "dev.vmd1.gossip.notification.replyAction")
    }
}
