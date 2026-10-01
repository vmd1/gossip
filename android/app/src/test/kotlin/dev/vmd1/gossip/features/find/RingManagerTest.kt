package dev.vmd1.gossip.features.find

import dev.vmd1.gossip.protocol.Envelope
import dev.vmd1.gossip.protocol.MessageType
import dev.vmd1.gossip.transport.MessageRouter
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class RingManagerTest {
    private class FakeRinger : Ringer {
        var starts = 0; var stops = 0
        override fun start() { starts++ }
        override fun stop() { stops++ }
    }

    private fun env(action: String, ringId: String) =
        Envelope(type = MessageType.DEVICE_RING, senderId = "peer", recipientId = "me", payload = RingManager.payload(action, ringId))

    @Test
    fun `start rings and stop silences`() = runTest {
        val router = MessageRouter(); val ringer = FakeRinger()
        val m = RingManager(router, ringer, this); m.start()
        router.dispatch(env("start", "a"))
        assertTrue(m.isRinging); assertEquals(1, ringer.starts)
        router.dispatch(env("stop", "b"))
        assertFalse(m.isRinging); assertEquals(1, ringer.stops)
        m.shutdown()
    }

    @Test
    fun `duplicate start is a no-op and cannot restart a stopped ring`() = runTest {
        val router = MessageRouter(); val ringer = FakeRinger()
        val m = RingManager(router, ringer, this); m.start()
        router.dispatch(env("start", "a"))
        router.dispatch(env("start", "a"))
        assertEquals(1, ringer.starts)
        router.dispatch(env("stop", "b"))
        router.dispatch(env("start", "a"))   // late redelivery of the original start
        assertFalse(m.isRinging); assertEquals(1, ringer.starts)
        router.dispatch(env("start", "c"))   // a genuinely new request does ring
        assertTrue(m.isRinging); assertEquals(2, ringer.starts)
        m.shutdown()
    }

    @Test
    fun `stop while silent and a second start while ringing are no-ops`() = runTest {
        val router = MessageRouter(); val ringer = FakeRinger()
        val m = RingManager(router, ringer, this); m.start()
        router.dispatch(env("stop", "x")); assertEquals(0, ringer.stops)
        router.dispatch(env("start", "a")); router.dispatch(env("start", "b"))
        assertEquals(1, ringer.starts)
        m.shutdown()
    }

    @Test
    fun `auto-stops after the timeout`() = runTest {
        val router = MessageRouter(); val ringer = FakeRinger()
        val scope = TestScope(testScheduler)
        val m = RingManager(router, ringer, scope, autoStopMs = 1_000); m.start()
        router.dispatch(env("start", "a"))
        scope.advanceTimeBy(999); assertTrue(m.isRinging)
        scope.advanceTimeBy(2); scope.testScheduler.runCurrent()
        assertFalse(m.isRinging); assertEquals(1, ringer.stops)
    }

    @Test
    fun `malformed or disabled-feature messages do nothing`() = runTest {
        val ringer = FakeRinger()
        val router = MessageRouter(isMessageAllowed = { false })
        val m = RingManager(router, ringer, this); m.start()
        router.dispatch(env("start", "a"))
        assertEquals(0, ringer.starts)
        val open = MessageRouter(); val m2 = RingManager(open, ringer, this); m2.start()
        open.dispatch(Envelope(type = MessageType.DEVICE_RING, senderId = "p"))  // no payload
        assertEquals(0, ringer.starts)
    }
}
