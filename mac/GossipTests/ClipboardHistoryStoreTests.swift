import XCTest
@testable import Gossip

final class ClipboardHistoryStoreTests: XCTestCase {
    private func makeStore(enabled: Bool = true) -> ClipboardHistoryStore {
        let defaults = UserDefaults(suiteName: "history-\(UUID().uuidString)")!
        let store = ClipboardHistoryStore(url: nil, defaults: defaults)
        store.isEnabled = enabled
        return store
    }

    func testOnByDefault() {
        let store = ClipboardHistoryStore(url: nil, defaults: UserDefaults(suiteName: "history-\(UUID().uuidString)")!)
        XCTAssertTrue(store.isEnabled)
    }

    func testDisabledStoreRecordsNothing() {
        let store = makeStore(enabled: false)
        store.record("hello", remote: false)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testRecopyMovesToTopWithoutDuplicating() {
        let store = makeStore()
        store.record("a", remote: false); store.record("b", remote: false); store.record("a", remote: false)
        XCTAssertEqual(store.entries.map(\.text), ["a", "b"])
        store.record("a", remote: false)
        XCTAssertEqual(store.entries.count, 2, "applying the same copy twice is a no-op")
    }

    func testPinsSurviveTrimAndSortFirst() {
        let store = makeStore()
        store.record("keep", remote: false)
        store.togglePin(store.entries[0].id)
        for i in 0..<(ClipboardHistoryStore.maxUnpinned + 5) { store.record("item \(i)", remote: false) }
        XCTAssertEqual(store.entries.filter { !$0.pinned }.count, ClipboardHistoryStore.maxUnpinned)
        XCTAssertEqual(store.filtered("").first?.text, "keep")
    }

    func testSearchBlankAndClear() {
        let store = makeStore()
        store.record("Hello World", remote: true); store.record("   ", remote: false); store.record("other", remote: false)
        XCTAssertEqual(store.filtered("world").map(\.text), ["Hello World"])
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testTurningOffWipesHistory() {
        let store = makeStore()
        store.record("x", remote: false)
        store.isEnabled = false
        XCTAssertTrue(store.entries.isEmpty)
    }
}
