package dev.vmd1.gossip.features.hotspot

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HotspotRequestGateTest {
    @Test
    fun `a nonce works once and the set is bounded`() {
        val gate = HotspotRequestGate(maxNonces = 3)
        assertTrue(gate.firstUse("a"))
        assertFalse(gate.firstUse("a"))
        gate.firstUse("b"); gate.firstUse("c"); gate.firstUse("d") // evicts "a"
        assertTrue(gate.firstUse("a"))
    }

    @Test
    fun `each address gets a request budget per window`() {
        var t = 0L
        val gate = HotspotRequestGate(now = { t }, maxPerWindow = 3, windowMs = 1000)
        repeat(3) { assertTrue(gate.allowRate("aa")) }
        assertFalse(gate.allowRate("aa"))
        assertTrue(gate.allowRate("bb")) // other addresses are independent
        t = 1500
        assertTrue(gate.allowRate("aa")) // the window moved on
    }

    @Test
    fun `address tracking is bounded`() {
        val gate = HotspotRequestGate(maxTrackedAddresses = 2)
        assertTrue(gate.allowRate("a")); assertTrue(gate.allowRate("b"))
        assertFalse(gate.allowRate("c")) // a flood of fresh addresses can't grow the table
    }

    @Test
    fun `requests are only fresh near the requester's clock`() {
        val now = 1_000_000_000L
        fun req(t: Long) = HotspotGattProtocol.ToggleRequestPayload("id", true, "n", t, "s")
        assertTrue(req(now).isFresh(now))
        assertTrue(req(now - 60_000).isFresh(now))
        assertFalse(req(now - HotspotGattProtocol.REQUEST_FRESHNESS_MS - 1).isFresh(now))
        assertFalse(req(now + HotspotGattProtocol.REQUEST_FRESHNESS_MS + 1).isFresh(now))
        assertFalse(req(0).isFresh(now)) // an old client that sends no timestamp
    }

    @Test
    fun `reassembly drops oversized messages and recovers for the next one`() {
        val r = HotspotGattProtocol.ChunkReassembler(maxBytes = 40)
        val big = ByteArray(100) { 1 }
        val chunks = HotspotGattProtocol.encodeChunks(big)
        var result: ByteArray? = byteArrayOf(9)
        for (c in chunks) result = r.feed(c)
        assertNull(result) // discarded, not delivered
        val ok = ByteArray(30) { 2 }
        var out: ByteArray? = null
        for (c in HotspotGattProtocol.encodeChunks(ok)) out = r.feed(c)
        assertArrayEquals(ok, out)
    }
}
