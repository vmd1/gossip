import XCTest
@testable import Gossip

final class MessagesTests: XCTestCase {
    func testDecodesThreadsAndSkipsMalformed() {
        let payload: JSONValue = .object(["threads": .array([
            .object(["id": .string("1"), "address": .string("+1555"), "name": .string("Ann"), "snippet": .string("hi"),
                     "date": .number(1_700_000_000_000), "outgoing": .bool(true), "unread": .number(2)]),
            .object(["address": .string("no id")]),
        ])])
        let threads = MessagesWire.threads(payload, phoneId: "p1", phoneName: "Pixel")
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].id, "p1|1", "ids are unique across phones")
        XCTAssertEqual(threads[0].phoneName, "Pixel")
        XCTAssertEqual(threads[0].title, "Ann")
        XCTAssertTrue(threads[0].outgoing)
        XCTAssertEqual(threads[0].unread, 2)
        XCTAssertEqual(threads[0].date.timeIntervalSince1970, 1_700_000_000)
    }

    func testHistoryIsSortedOldestFirst() {
        let payload: JSONValue = .object(["messages": .array([
            .object(["id": .string("b"), "date": .number(200), "outgoing": .bool(true), "body": .string("2")]),
            .object(["id": .string("a"), "date": .number(100), "outgoing": .bool(false), "body": .string("1")]),
        ])])
        XCTAssertEqual(MessagesWire.messages(payload).map(\.id), ["a", "b"])
    }

    func testReasonsAreHumanReadable() {
        XCTAssertNil(MessagesWire.reasonText(nil))
        XCTAssertTrue(MessagesWire.reasonText("disabled")!.contains("turned off"))
        XCTAssertTrue(MessagesWire.reasonText("no_permission")!.contains("permission"))
    }

    func testMessagesIsOnByDefaultAndOwnsItsPrefix() {
        XCTAssertEqual(FeatureSettings.feature(forMessageType: "messages.send"), .messages)
        XCTAssertEqual(FeatureSettings.feature(forMessageType: "messages.state"), .messages)
        let settings = FeatureSettings(defaults: UserDefaults(suiteName: "msg-\(UUID().uuidString)")!)
        XCTAssertTrue(settings.isMessageAllowed(type: "messages.threads"))
    }
}

final class MessagesLauncherTests: XCTestCase {
    func testMessagesLauncherIsItsOwnApp() {
        let installer = LauncherInstaller.messages()
        XCTAssertEqual(installer.launcherName, "Gossip Messages.app")
        XCTAssertEqual(installer.title, "Gossip Messages")
        XCTAssertNotEqual(installer.launcherBundleIdentifier, LauncherInstaller().launcherBundleIdentifier)
    }
}
