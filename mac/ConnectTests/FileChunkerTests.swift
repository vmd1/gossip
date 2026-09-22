import XCTest
import CryptoKit
@testable import Connect

final class FileChunkerTests: XCTestCase {
    func testChunksSplitAtExactBoundary() {
        let data = Data(repeating: 0x42, count: FileChunker.chunkSize * 2)
        let chunks = FileChunker.chunks(for: data)

        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].count, FileChunker.chunkSize)
        XCTAssertEqual(chunks[1].count, FileChunker.chunkSize)
    }

    func testChunksSplitWithRemainder() {
        let data = Data((0..<(FileChunker.chunkSize + 100)).map { UInt8($0 % 256) })
        let chunks = FileChunker.chunks(for: data)

        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].count, FileChunker.chunkSize)
        XCTAssertEqual(chunks[1].count, 100)
    }

    func testChunksRejoinToOriginalBytes() {
        var generator = SystemRandomNumberGenerator()
        let data = Data((0..<50_000).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let chunks = FileChunker.chunks(for: data, chunkSize: 4096)

        let rejoined = chunks.reduce(into: Data()) { $0.append($1) }
        XCTAssertEqual(rejoined, data)
    }

    func testEmptyFileYieldsSingleEmptyChunk() {
        let chunks = FileChunker.chunks(for: Data())
        XCTAssertEqual(chunks, [Data()])
    }

    func testSmallFileYieldsSingleChunk() {
        let data = Data("hello connect".utf8)
        let chunks = FileChunker.chunks(for: data)
        XCTAssertEqual(chunks, [data])
    }

    func testSha256HexMatchesIncrementalHashOfChunks() {
        let data = Data((0..<10_000).map { UInt8($0 % 251) })
        let wholeFileHex = FileChunker.sha256Hex(of: data)

        // Simulates the receiver: hash chunks incrementally as they arrive,
        // exactly like `FileTransferManager`'s `IncomingTransfer.hasher` does.
        var hasher = SHA256()
        for chunk in FileChunker.chunks(for: data, chunkSize: 4096) {
            hasher.update(data: chunk)
        }
        let incrementalHex = FileChunker.hex(hasher.finalize())

        XCTAssertEqual(wholeFileHex, incrementalHex)
    }

    func testSha256HexDetectsCorruption() {
        let original = Data([1, 2, 3, 4, 5])
        let corrupted = Data([1, 2, 3, 4, 6])

        XCTAssertNotEqual(FileChunker.sha256Hex(of: original), FileChunker.sha256Hex(of: corrupted))
    }

    func testSha256HexIsDeterministic() {
        let data = Data("Connect file transfer".utf8)
        XCTAssertEqual(FileChunker.sha256Hex(of: data), FileChunker.sha256Hex(of: data))
    }
}
