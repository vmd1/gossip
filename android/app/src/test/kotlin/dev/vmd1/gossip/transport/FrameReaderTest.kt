package dev.vmd1.gossip.transport

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.DataInputStream
import java.io.EOFException
import java.nio.ByteBuffer

class FrameReaderTest {
    private fun stream(declared: Int, body: ByteArray) =
        DataInputStream(ByteArrayInputStream(ByteBuffer.allocate(4 + body.size).putInt(declared).put(body).array()))

    @Test
    fun `reads a frame within the limit`() {
        val body = ByteArray(20_000) { it.toByte() }
        assertArrayEquals(body, TransportManager.readFrame(stream(body.size, body)))
    }

    @Test
    fun `rejects a frame over the handshake limit`() {
        val size = TransportManager.MAX_HANDSHAKE_FRAME_BYTES + 1
        assertThrows(IllegalArgumentException::class.java) {
            TransportManager.readFrame(stream(size, ByteArray(size)), TransportManager.MAX_HANDSHAKE_FRAME_BYTES)
        }
    }

    @Test
    fun `a declared length with no body fails without allocating it`() {
        assertThrows(EOFException::class.java) {
            TransportManager.readFrame(stream(10_000_000, ByteArray(0)))
        }
    }
}
