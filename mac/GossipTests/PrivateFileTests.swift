import XCTest
@testable import Gossip

final class PrivateFileTests: XCTestCase {
    func testWrittenFileIsOwnerOnlyAndReplacesAtomically() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pf-\(UUID().uuidString)")
        PrivateFile.ensureDirectory(dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("secret.json")

        XCTAssertTrue(PrivateFile.write(Data("one".utf8), to: file))
        XCTAssertTrue(PrivateFile.write(Data("two".utf8), to: file))

        XCTAssertEqual(try Data(contentsOf: file), Data("two".utf8))
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        let dirMode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        XCTAssertEqual(fileMode, 0o600)
        XCTAssertEqual(dirMode, 0o700)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["secret.json"])
    }
}
