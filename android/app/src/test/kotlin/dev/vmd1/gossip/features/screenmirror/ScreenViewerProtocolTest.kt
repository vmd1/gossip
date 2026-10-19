package dev.vmd1.gossip.features.screenmirror

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer

class ScreenViewerProtocolTest {
    @Test
    fun `parses video config and key frame flags`() {
        val flags = BridgeMessage.CONFIG_FLAG or 5L
        val msg = BridgeMessage.parse(byteArrayOf(0) + ByteBuffer.allocate(8).putLong(flags).array() + byteArrayOf(1, 2, 3)) as BridgeMessage.Video
        assertTrue(msg.isConfig); assertEquals(5L, msg.ptsUs)
        assertArrayEquals(byteArrayOf(1, 2, 3), msg.payload)
        val key = BridgeMessage.parse(byteArrayOf(0) + ByteBuffer.allocate(8).putLong(BridgeMessage.KEY_FRAME_FLAG).array() + byteArrayOf(9)) as BridgeMessage.Video
        assertTrue(key.isKeyFrame)
    }

    @Test
    fun `parses size audio and rejects malformed`() {
        assertEquals(BridgeMessage.Size(1080, 2400), BridgeMessage.parse(byteArrayOf(1) + ByteBuffer.allocate(8).putInt(1080).putInt(2400).array()))
        val audio = BridgeMessage.parse(byteArrayOf(3) + ByteArray(8) + byteArrayOf(7, 8)) as BridgeMessage.Audio
        assertArrayEquals(byteArrayOf(7, 8), audio.pcm)
        assertNull(BridgeMessage.parse(byteArrayOf(1, 0, 0)))
        assertNull(BridgeMessage.parse(byteArrayOf(0, 1)))
        assertNull(BridgeMessage.parse(byteArrayOf(9)))
        assertNull(BridgeMessage.parse(byteArrayOf()))
    }

    @Test
    fun `parses header with and without audio`() {
        val h = BridgeStreamHeader.parse("""{"codec":"h264","width":1080,"height":2400,"deviceName":"Pixel","audio":{"codec":"raw","sampleRate":48000,"channels":2,"format":"s16le"}}""")!!
        assertEquals("Pixel", h.deviceName); assertEquals(48000, h.audioSampleRate); assertEquals(2, h.audioChannels)
        val none = BridgeStreamHeader.parse("""{"codec":"h264","width":1,"height":2,"audio":null}""")!!
        assertNull(none.audioSampleRate)
        assertNull(BridgeStreamHeader.parse("not json"))
    }

    @Test
    fun `touch encoding matches scrcpy layout`() {
        val b = ScrcpyControl.touch(ScrcpyControl.ACTION_DOWN, 0, 10, 20, 1080, 2400)
        assertEquals(32, b.size)
        val buf = ByteBuffer.wrap(b)
        assertEquals(2, buf.get().toInt()); assertEquals(0, buf.get().toInt()); assertEquals(0L, buf.long)
        assertEquals(10, buf.int); assertEquals(20, buf.int)
        assertEquals(1080, buf.short.toInt() and 0xffff); assertEquals(2400, buf.short.toInt() and 0xffff)
        assertEquals(0xffff, buf.short.toInt() and 0xffff)
        assertEquals(0, ScrcpyControl.touch(ScrcpyControl.ACTION_UP, 0, 0, 0, 1, 1)[26].toInt()) // pressure 0 on up
    }

    @Test
    fun `key text and reset encodings`() {
        assertEquals(28, ScrcpyControl.keyPress(ScrcpyControl.KEY_BACK).size)
        assertArrayEquals(byteArrayOf(17), ScrcpyControl.RESET_VIDEO)
        assertNull(ScrcpyControl.text(""))
        val long = ScrcpyControl.text("€".repeat(200))!!
        assertTrue(long.size - 5 <= 300); assertEquals(0, (long.size - 5) % 3)
    }
}
