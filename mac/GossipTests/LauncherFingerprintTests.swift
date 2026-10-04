import XCTest
@testable import Gossip

final class LauncherFingerprintTests: XCTestCase {
    private func makeBundle(resource: String) throws -> URL {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("fp-\(UUID().uuidString).app")
        let fm = FileManager.default
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try Data("exe".utf8).write(to: app.appendingPathComponent("Contents/MacOS/launcher"))
        try Data(resource.utf8).write(to: app.appendingPathComponent("Contents/Resources/data.txt"))
        return app
    }

    func testFingerprintCoversTheWholeBundleNotJustTheExecutable() throws {
        let a = try makeBundle(resource: "one"), b = try makeBundle(resource: "one"), c = try makeBundle(resource: "two")
        defer { [a, b, c].forEach { try? FileManager.default.removeItem(at: $0) } }
        XCTAssertNotNil(LauncherInstaller.fingerprint(of: a))
        XCTAssertEqual(LauncherInstaller.fingerprint(of: a), LauncherInstaller.fingerprint(of: b))
        XCTAssertNotEqual(LauncherInstaller.fingerprint(of: a), LauncherInstaller.fingerprint(of: c)) // same executable, altered resource
        XCTAssertNil(LauncherInstaller.fingerprint(of: a.appendingPathComponent("missing")))
    }
}
