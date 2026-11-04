import XCTest
@testable import Gossip

final class RicherNotificationTests: XCTestCase {
    func testProgressLine() {
        XCTAssertEqual(NotificationMirrorManager.progressLine(NotificationLive(kind: "progress", progress: 3, max: 10, indeterminate: nil, chronometerBase: nil)), "Progress: 30%")
        XCTAssertEqual(NotificationMirrorManager.progressLine(NotificationLive(kind: "progress", progress: 0, max: 0, indeterminate: true, chronometerBase: nil)), "In progress…")
        XCTAssertNil(NotificationMirrorManager.progressLine(NotificationLive(kind: "timer", progress: nil, max: nil, indeterminate: nil, chronometerBase: 1)))
        XCTAssertNil(NotificationMirrorManager.progressLine(nil))
    }

    func testCategoryOnlyForCustomLayoutsAndStablePerLayout() {
        XCTAssertNil(NotificationMirrorManager.category(hasReply: true, code: false, actions: [], smartReplies: []))
        let a = [NotificationActionInfo(index: 1, title: "Archive")]
        let c1 = NotificationMirrorManager.category(hasReply: true, code: false, actions: a, smartReplies: ["Ok"])
        let c2 = NotificationMirrorManager.category(hasReply: true, code: false, actions: a, smartReplies: ["Ok"])
        let c3 = NotificationMirrorManager.category(hasReply: true, code: false, actions: a, smartReplies: ["No"])
        XCTAssertEqual(c1?.identifier, c2?.identifier)
        XCTAssertNotEqual(c1?.identifier, c3?.identifier)
        XCTAssertEqual(c1?.actions.count, 3) // smart reply, button, reply
    }

    func testOlderPayloadsStillDecode() throws {
        let json = #"{"id":"k","appPackage":"p","appName":"A","title":"t","body":"b","hasReplyAction":false,"timestamp":1}"#
        let p = try JSONDecoder().decode(NotificationPostedPayload.self, from: Data(json.utf8))
        XCTAssertNil(p.avatarBase64); XCTAssertNil(p.actions); XCTAssertNil(p.live)
    }
}
