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

    // MARK: Images

    private func makeImageStore() -> (ClipboardHistoryStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hist-img-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ClipboardHistoryStore(url: nil, imageDirectory: dir, defaults: UserDefaults(suiteName: "history-\(UUID().uuidString)")!)
        return (store, dir)
    }

    private func files(_ dir: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".png") } }

    func testImageIsStoredAndTheSameImageMovesToTheTop() {
        let (store, dir) = makeImageStore()
        let a = Data([1, 2, 3]), b = Data([4, 5, 6])
        store.recordImage(a, width: 10, height: 20, remote: false)
        store.recordImage(b, width: 1, height: 1, remote: true)
        store.recordImage(a, width: 10, height: 20, remote: false)
        XCTAssertEqual(store.entries.count, 2, "the same bytes twice is a no-op apart from moving to the top")
        XCTAssertEqual(store.entries[0].text, "Image 10×20")
        XCTAssertEqual(store.imageData(for: store.entries[0]), a)
        XCTAssertEqual(files(dir).count, 2)
    }

    func testRemovingClearingAndTrimmingDeleteImageFiles() {
        let (store, dir) = makeImageStore()
        for i in 0..<(ClipboardHistoryStore.maxUnpinned + 3) { store.recordImage(Data([UInt8(i % 250), UInt8(i / 250), 9]), width: 1, height: 1, remote: false) }
        XCTAssertEqual(files(dir).count, ClipboardHistoryStore.maxUnpinned, "trimmed entries lose their files")
        store.remove(store.entries[0].id)
        XCTAssertEqual(files(dir).count, ClipboardHistoryStore.maxUnpinned - 1)
        store.clear()
        XCTAssertTrue(files(dir).isEmpty)
    }

    func testOversizedAndDisabledImagesAreSkipped() {
        let (store, dir) = makeImageStore()
        store.recordImage(Data(count: ClipboardHistoryStore.maxImageBytes + 1), width: 1, height: 1, remote: false)
        XCTAssertTrue(store.entries.isEmpty)
        store.isEnabled = false
        store.recordImage(Data([1]), width: 1, height: 1, remote: false)
        XCTAssertTrue(store.entries.isEmpty && files(dir).isEmpty)
    }

    func testOlderHistoryFilesStillDecode() throws {
        let json = #"[{"id":"\#(UUID().uuidString)","text":"hi","date":0,"pinned":false,"remote":false}]"#
        let entries = try JSONDecoder().decode([ClipboardHistoryEntry].self, from: Data(json.utf8))
        XCTAssertEqual(entries.first?.text, "hi"); XCTAssertFalse(entries[0].isImage)
    }
}
