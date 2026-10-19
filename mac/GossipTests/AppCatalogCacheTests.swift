import XCTest
import AppKit
@testable import Gossip

final class AppCatalogCacheTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("appcache-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func png() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    func testRemembersAppsAndIconsAcrossLaunches() {
        let a = AppCatalogCache(root: root)
        a.replaceApps([.init(package: "com.example.notes", label: "Notes", version: 5)], for: "phone")
        a.storeIcon(png(), package: "com.example.notes", version: 5, deviceId: "phone")
        let b = AppCatalogCache(root: root) // a "new launch"
        XCTAssertEqual(b.apps(for: "phone").map(\.label), ["Notes"])
        XCTAssertNotNil(b.icon(for: "com.example.notes", version: 5, deviceId: "phone"))
        XCTAssertEqual(b.haveIcons(for: "phone"), ["com.example.notes@5"])
    }

    func testOnlyMissingOrChangedIconsNeedFetching() {
        let cache = AppCatalogCache(root: root)
        let first = cache.replaceApps([.init(package: "a.b", label: "A", version: 1), .init(package: "c.d", label: "C", version: 1)], for: "p")
        XCTAssertEqual(Set(first), ["a.b", "c.d"], "nothing cached yet")
        cache.storeIcon(png(), package: "a.b", version: 1, deviceId: "p")
        cache.storeIcon(png(), package: "c.d", version: 1, deviceId: "p")
        let same = cache.replaceApps([.init(package: "a.b", label: "A", version: 1), .init(package: "c.d", label: "C", version: 1)], for: "p")
        XCTAssertTrue(same.isEmpty, "unchanged apps fetch nothing")
        let updated = cache.replaceApps([.init(package: "a.b", label: "A", version: 2), .init(package: "c.d", label: "C", version: 1)], for: "p")
        XCTAssertEqual(updated, ["a.b"], "only the updated app's icon is re-fetched")
    }

    func testUninstalledAppsAreDropped() {
        let cache = AppCatalogCache(root: root)
        cache.replaceApps([.init(package: "a.b", label: "A", version: 1)], for: "p")
        cache.storeIcon(png(), package: "a.b", version: 1, deviceId: "p")
        cache.replaceApps([], for: "p")
        XCTAssertTrue(cache.apps(for: "p").isEmpty)
        XCTAssertNil(cache.icon(for: "a.b", version: 1, deviceId: "p"))
        XCTAssertTrue(cache.haveIcons(for: "p").isEmpty)
    }

    func testHostileNamesNeverEscapeTheFolder() {
        let cache = AppCatalogCache(root: root)
        cache.storeIcon(png(), package: "../../etc/passwd", version: 1, deviceId: "p")
        cache.storeIcon(png(), package: "a.b", version: 1, deviceId: "../escape")
        XCTAssertTrue(cache.haveIcons(for: "p").isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("escape").path))
    }

    func testRepeatedStoresAreHarmless() {
        let cache = AppCatalogCache(root: root)
        cache.storeIcon(png(), package: "a.b", version: 1, deviceId: "p")
        cache.storeIcon(png(), package: "a.b", version: 1, deviceId: "p")
        XCTAssertEqual(cache.haveIcons(for: "p"), ["a.b@1"])
    }
}
