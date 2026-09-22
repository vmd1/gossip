package com.connect.features.filetransfer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertArrayEquals
import org.junit.Test
import kotlin.random.Random

class FileChunkerTest {

    @Test
    fun `chunks split at exact boundary`() {
        val data = ByteArray(FileChunker.CHUNK_SIZE * 2) { 0x42 }
        val chunks = FileChunker.chunks(data)

        assertEquals(2, chunks.size)
        assertEquals(FileChunker.CHUNK_SIZE, chunks[0].size)
        assertEquals(FileChunker.CHUNK_SIZE, chunks[1].size)
    }

    @Test
    fun `chunks split with remainder`() {
        val data = ByteArray(FileChunker.CHUNK_SIZE + 100) { (it % 256).toByte() }
        val chunks = FileChunker.chunks(data)

        assertEquals(2, chunks.size)
        assertEquals(FileChunker.CHUNK_SIZE, chunks[0].size)
        assertEquals(100, chunks[1].size)
    }

    @Test
    fun `chunks rejoin to original bytes`() {
        val random = Random(42)
        val data = random.nextBytes(50_000)
        val chunks = FileChunker.chunks(data, chunkSize = 4096)

        val rejoined = chunks.fold(ByteArray(0)) { acc, chunk -> acc + chunk }
        assertArrayEquals(data, rejoined)
    }

    @Test
    fun `empty file yields single empty chunk`() {
        val chunks = FileChunker.chunks(ByteArray(0))
        assertEquals(1, chunks.size)
        assertEquals(0, chunks[0].size)
    }

    @Test
    fun `small file yields single chunk`() {
        val data = "hello connect".toByteArray()
        val chunks = FileChunker.chunks(data)
        assertEquals(1, chunks.size)
        assertArrayEquals(data, chunks[0])
    }

    @Test
    fun `sha256 hex matches incremental hash of chunks`() {
        val data = ByteArray(10_000) { (it % 251).toByte() }
        val wholeFileHex = FileChunker.sha256Hex(data)

        // Simulates the receiver: hash chunks incrementally as they arrive, exactly
        // like FileTransferManager.IncomingTransfer.hasher does.
        val hasher = IncrementalSha256()
        for (chunk in FileChunker.chunks(data, chunkSize = 4096)) {
            hasher.update(chunk)
        }

        assertEquals(wholeFileHex, hasher.hex())
    }

    @Test
    fun `sha256 hex detects corruption`() {
        val original = byteArrayOf(1, 2, 3, 4, 5)
        val corrupted = byteArrayOf(1, 2, 3, 4, 6)

        assertNotEquals(FileChunker.sha256Hex(original), FileChunker.sha256Hex(corrupted))
    }

    @Test
    fun `sha256 hex is deterministic`() {
        val data = "Connect file transfer".toByteArray()
        assertEquals(FileChunker.sha256Hex(data), FileChunker.sha256Hex(data))
    }
}
