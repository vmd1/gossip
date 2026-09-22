import Foundation
import CryptoKit

/// Pure chunking/hashing helpers for file transfer, deliberately kept
/// independent of `TransportManager`/disk I/O so the logic that matters most
/// (splitting bytes into wire chunks, and computing/verifying a SHA-256 over
/// them) can be unit tested without a live connection. See the `file.chunk`
/// convention documented in `schema/message-types.md`.
enum FileChunker {
    /// Wire chunk size for `file.chunk` frames: 256 KiB.
    static let chunkSize = 256 * 1024

    /// Splits `data` into ordered, ≤`chunkSize`-byte pieces. A zero-byte
    /// input still yields exactly one (empty) chunk, so an empty file gets a
    /// single `file.chunk`/raw-frame pair rather than none at all.
    static func chunks(for data: Data, chunkSize: Int = FileChunker.chunkSize) -> [Data] {
        guard !data.isEmpty else { return [Data()] }
        precondition(chunkSize > 0, "chunkSize must be positive")

        var result: [Data] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            result.append(data.subdata(in: offset..<end))
            offset = end
        }
        return result
    }

    /// Lowercase hex SHA-256 of `data`, matching the `sha256` field format
    /// used by `file.complete`.
    static func sha256Hex(of data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
