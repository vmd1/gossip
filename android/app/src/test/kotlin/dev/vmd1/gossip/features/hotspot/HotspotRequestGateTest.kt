package dev.vmd1.gossip.features.hotspot

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The gate, chunking and signed payloads are the core's (tested there); these check the Android wrappers reach it. */
class HotspotRequestGateTest {
    @Test
    fun `a nonce works once`() {
        val gate = HotspotRequestGate()
        assertTrue(gate.firstUse("a"))
        assertFalse(gate.firstUse("a"))
        assertTrue(gate.firstUse("b"))
    }

    @Test
    fun `each address gets a request budget per window`() {
        var t = 0L
        val gate = HotspotRequestGate(now = { t })
        var allowed = 0
        repeat(20) { if (gate.allowRate("aa")) allowed++ }
        assertTrue("some, but not all, are allowed", allowed in 1..19)
        assertTrue(gate.allowRate("bb")) // other addresses are independent
        t = 10 * 60_000
        assertTrue(gate.allowRate("aa")) // the window moved on
    }

    @Test
    fun `requests are only fresh near the requester's clock`() {
        val now = 1_000_000_000L
        fun req(t: Long) = HotspotGattProtocol.ToggleRequestPayload("id", true, "n", t, "s")
        assertTrue(req(now).isFresh(now))
        assertFalse(req(now - HotspotGattProtocol.REQUEST_FRESHNESS_MS - 1).isFresh(now))
        assertFalse(req(0).isFresh(now)) // an old client that sends no timestamp
    }

    @Test
    fun `chunks reassemble and a signed request round trips and verifies`() {
        val message = ByteArray(100) { it.toByte() }
        val r = HotspotGattProtocol.ChunkReassembler()
        var out: ByteArray? = null
        for (c in HotspotGattProtocol.encodeChunks(message)) out = r.feed(c)
        assertArrayEquals(message, out)

        val seed = ByteArray(32) { 7 }
        val request = HotspotGattProtocol.ToggleRequestPayload.create("dev", true, seed)
        val decoded = HotspotGattProtocol.decodeRequest(HotspotGattProtocol.encodeRequest(request))
        assertEquals(request, decoded)
        assertNull(HotspotGattProtocol.decodeRequest(byteArrayOf(1, 2, 3)))
        assertNotNull(decoded)
    }
}
