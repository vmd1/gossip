package dev.vmd1.gossip.features.clipboard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.gossip_ffi.ClipboardGuard

/** The loop suppression and content policy are the core's `ClipboardGuard`; these check they behave across the bindings. */
class ClipboardSyncManagerTest {
    @Test
    fun `a local copy is published once and an echo of a peer's value is suppressed`() {
        val g = ClipboardGuard()
        assertTrue(g.outgoingText("me", "hello", false)!!.contains("\"text\":\"hello\""))
        assertNull("the same value is not published again", g.outgoingText("me", "hello", false))
        assertEquals("from-peer", g.incomingText("""{"text":"from-peer","sourceDeviceId":"peer"}"""))
        assertNull("our own write echoed back by the next poll", g.outgoingText("me", "from-peer", false))
        assertNotNull(g.outgoingText("me", "new local", false))
        assertNull("sensitive content is never published", g.outgoingText("me", "secret", true))
    }

    @Test
    fun `images are suppressed like text`() {
        val png = byteArrayOf(0x89.toByte(), 'P'.code.toByte(), 'N'.code.toByte(), 'G'.code.toByte(), 13, 10, 26, 10) +
            ByteArray(4) + "IHDR".toByteArray() + byteArrayOf(0, 0, 0, 4, 0, 0, 0, 4) + ByteArray(8)
        val g = ClipboardGuard()
        assertNotNull(g.outgoingImage("me", png, false))
        assertNull(g.outgoingImage("me", png, false))
        assertNull(g.outgoingImage("me", png, true))
    }

    @Test
    fun `size limits come from the core`() {
        assertTrue(ClipboardPolicy.textAllowed("a".repeat(ClipboardPolicy.MAX_TEXT_BYTES)))
        assertFalse(ClipboardPolicy.textAllowed("a".repeat(ClipboardPolicy.MAX_TEXT_BYTES + 1)))
        assertFalse(ClipboardPolicy.imageBytesAllowed(0))
        assertTrue(ClipboardPolicy.imageBytesAllowed(ClipboardPolicy.MAX_IMAGE_BYTES))
        assertFalse(ClipboardPolicy.imageBytesAllowed(ClipboardPolicy.MAX_IMAGE_BYTES + 1))
    }
}
