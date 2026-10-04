package dev.vmd1.gossip.transport

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class InboundRateLimiterTest {
    @Test
    fun `allows a burst up to the limit then refuses until the window passes`() {
        val l = InboundRateLimiter(limitPerSecond = 3)
        repeat(3) { assertTrue(l.allow(nowMs = 10_000)) }
        assertFalse(l.allow(nowMs = 10_500))
        assertTrue(l.allow(nowMs = 11_100))
    }
}
