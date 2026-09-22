package com.connect.features.filetransfer

import java.security.MessageDigest

/**
 * Pure chunking/hashing helpers for file transfer, deliberately kept independent of
 * Android APIs (ContentResolver, MediaStore) and of [com.connect.transport.TransportManager]
 * so the logic that matters most — splitting bytes into wire chunks, and computing a
 * SHA-256 over them — can be unit tested on the JVM without instrumentation. See the
 * `file.chunk` convention documented in `schema/message-types.md`.
 */
object FileChunker {
    /** Wire chunk size for `file.chunk` frames: 256 KiB. */
    const val CHUNK_SIZE = 256 * 1024

    /**
     * Splits [data] into ordered, at-most-[chunkSize]-byte pieces. A zero-byte input
     * still yields exactly one (empty) chunk, so an empty file gets a single
     * `file.chunk`/raw-frame pair rather than none at all.
     */
    fun chunks(data: ByteArray, chunkSize: Int = CHUNK_SIZE): List<ByteArray> {
        require(chunkSize > 0) { "chunkSize must be positive" }
        if (data.isEmpty()) return listOf(ByteArray(0))

        val result = mutableListOf<ByteArray>()
        var offset = 0
        while (offset < data.size) {
            val end = minOf(offset + chunkSize, data.size)
            result.add(data.copyOfRange(offset, end))
            offset = end
        }
        return result
    }

    /** Lowercase hex SHA-256 of [data], matching the `sha256` field format used by `file.complete`. */
    fun sha256Hex(data: ByteArray): String = toHex(MessageDigest.getInstance("SHA-256").digest(data))

    fun toHex(bytes: ByteArray): String = buildString(bytes.size * 2) {
        for (b in bytes) {
            append(HEX_CHARS[(b.toInt() shr 4) and 0xF])
            append(HEX_CHARS[b.toInt() and 0xF])
        }
    }

    private val HEX_CHARS = "0123456789abcdef".toCharArray()
}

/**
 * Incrementally hashes chunks as they're written during a receive, so the running
 * SHA-256 can be checked against the sender's `file.complete` value without re-reading
 * the file from disk/`ContentResolver`.
 */
class IncrementalSha256 {
    private val digest = MessageDigest.getInstance("SHA-256")

    fun update(chunk: ByteArray) {
        digest.update(chunk)
    }

    fun hex(): String = FileChunker.toHex(digest.digest())
}
