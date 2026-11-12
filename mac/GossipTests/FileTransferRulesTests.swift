import XCTest
@testable import Gossip

final class FileTransferRulesTests: XCTestCase {
    private struct Sanitize: Decodable { let raw: String; let name: String }
    private struct Unique: Decodable { let name: String; let taken: [String]; let result: String }
    private struct Chunks: Decodable { let size: Int64; let chunkSize: Int; let count: Int; let lastLength: Int }
    private struct Resume: Decodable { let received: [Int]; let next: Int }
    private struct Cases: Decodable { let sanitize: [Sanitize]; let unique: [Unique]; let chunks: [Chunks]; let resume: [Resume] }

    /// The shared cases (`schema/file-transfer-cases.json`) the Android rules pass too.
    private func load() throws -> Cases {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("schema/file-transfer-cases.json")
        return try JSONDecoder().decode(Cases.self, from: Data(contentsOf: url))
    }

    func testSharedCases() throws {
        let cases = try load()
        XCTAssertFalse(cases.sanitize.isEmpty)
        for c in cases.sanitize { XCTAssertEqual(FileTransferRules.sanitizeName(c.raw), c.name, c.raw) }
        for c in cases.unique {
            let taken = Set(c.taken)
            XCTAssertEqual(FileTransferRules.uniqueName(c.name) { taken.contains($0) }, c.result, c.name)
        }
        for c in cases.chunks {
            let count = FileTransferRules.chunkCount(size: c.size, chunkSize: c.chunkSize)
            XCTAssertEqual(count, c.count)
            if count > 0 { XCTAssertEqual(FileTransferRules.chunkLength(size: c.size, chunkSize: c.chunkSize, index: count - 1), c.lastLength) }
        }
        for c in cases.resume { XCTAssertEqual(FileTransferRules.nextIndex(received: Set(c.received)), c.next) }
    }

    func testLongNamesKeepTheirExtension() {
        let name = FileTransferRules.sanitizeName(String(repeating: "a", count: 300) + ".pdf")
        XCTAssertEqual(name.count, FileTransferRules.maxNameLength)
        XCTAssertTrue(name.hasSuffix(".pdf"))
    }
}
