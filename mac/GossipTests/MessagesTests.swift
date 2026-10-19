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

final class ContactsTests: XCTestCase {
    private let ann = PhoneContact(id: "1", name: "Ann Lee", numbers: ["+44 7700 900123"])
    private let bob = PhoneContact(id: "2", name: "Bob Stone", numbers: ["07911 123456", "+1 555 010 9999"])

    func testSuggestionsByNameWordStartThenContains() {
        let found = ContactMatching.suggestions(for: "le", in: [ann, bob])
        XCTAssertEqual(found.first?.contact.name, "Ann Lee", "word start (Lee) beats contains")
        XCTAssertEqual(ContactMatching.suggestions(for: "stone", in: [ann, bob]).map(\.contact.name), ["Bob Stone"])
        XCTAssertTrue(ContactMatching.suggestions(for: "", in: [ann, bob]).isEmpty)
        XCTAssertTrue(ContactMatching.suggestions(for: "zz", in: [ann, bob]).isEmpty)
    }

    func testSuggestionsByNumberUseTheMatchingNumber() {
        let found = ContactMatching.suggestions(for: "555010", in: [ann, bob])
        XCTAssertEqual(found.first?.contact.name, "Bob Stone")
        XCTAssertEqual(found.first?.number, "+1 555 010 9999")
    }

    func testNumbersCompareAcrossFormats() {
        XCTAssertEqual(ContactMatching.normalize("+44 7700 900123"), ContactMatching.normalize("07700900123"))
    }

    func testPagesAssembleOnlyWhenComplete() {
        var a = ContactsAssembler()
        XCTAssertNil(a.add(digest: "d", page: 1, pages: 2, contacts: [bob]))
        XCTAssertNil(a.add(digest: "d", page: 1, pages: 2, contacts: [bob]), "a repeated page changes nothing")
        XCTAssertEqual(a.add(digest: "d", page: 0, pages: 2, contacts: [ann])?.map(\.name), ["Ann Lee", "Bob Stone"])
    }

    func testNewDigestRestartsCollection() {
        var a = ContactsAssembler()
        _ = a.add(digest: "old", page: 0, pages: 2, contacts: [ann])
        XCTAssertNil(a.add(digest: "new", page: 1, pages: 2, contacts: [bob]), "the stale page of the old list is dropped")
        XCTAssertEqual(a.add(digest: "new", page: 0, pages: 2, contacts: [ann])?.count, 2)
    }

    func testCacheRoundTripAndPathSafety() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("contacts-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ContactsCache(root: dir)
        cache.save(.init(digest: "x", contacts: [ann]), for: "phone")
        XCTAssertEqual(ContactsCache(root: dir).load("phone")?.contacts, [ann])
        cache.save(.init(digest: "x", contacts: [ann]), for: "../escape")
        XCTAssertNil(cache.load("../escape"))
    }
}
