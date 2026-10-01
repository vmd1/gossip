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

    private fun ringState(from: String, ringing: Boolean) = Envelope(
        type = MessageType.DEVICE_RING_STATE, senderId = from, recipientId = "me",
        payload = kotlinx.serialization.json.buildJsonObject { put("ringing", kotlinx.serialization.json.JsonPrimitive(ringing)) }
    )

    private fun states(sent: List<Envelope>) = sent.filter { it.type == MessageType.DEVICE_RING_STATE }
        .map { it.recipientId to it.payload["ringing"].toString() }

    @Test
    fun `reports ring_state to the requester when ringing starts and stops, however it stops`() = runTest {
        val router = MessageRouter(); val sent = mutableListOf<Envelope>()
        val scope = TestScope(testScheduler)
        val m = RingManager(router, FakeRinger(), scope, autoStopMs = 1_000, selfId = "me", send = { sent += it }); m.start()
        router.dispatch(env("start", "a"))                       // requester is "peer"
        m.stopRinging()                                          // local Stop
        assertEquals(listOf("peer" to "true", "peer" to "false"), states(sent))
        sent.clear()
        router.dispatch(env("start", "b")); scope.advanceTimeBy(1_001); scope.testScheduler.runCurrent()   // auto-stop
        assertEquals(listOf("peer" to "true", "peer" to "false"), states(sent))
        sent.clear()
        router.dispatch(env("start", "c")); router.dispatch(env("stop", "d"))                              // stop message
        assertEquals(listOf("peer" to "true", "peer" to "false"), states(sent))
        sent.clear()
        router.dispatch(env("stop", "e")); router.dispatch(env("start", "c"))   // no-ops send nothing
        assertEquals(0, sent.size)
        m.shutdown()
    }

    @Test
    fun `toggleRing sends start then stop and tracks the ringing peer`() = runTest {
        val router = MessageRouter(); val sent = mutableListOf<Envelope>()
        val m = RingManager(router, FakeRinger(), TestScope(testScheduler), selfId = "me", send = { sent += it }); m.start()
        m.toggleRing("phone")
        assertEquals(setOf("phone"), m.ringingPeers.value)
        assertEquals("start", sent.last().payload["action"].toString().trim('"'))
        assertEquals("phone", sent.last().recipientId)
        m.toggleRing("phone")
        assertEquals(emptySet<String>(), m.ringingPeers.value)
        assertEquals("stop", sent.last().payload["action"].toString().trim('"'))
        m.shutdown()
    }

    @Test
    fun `peer ring_state updates the button state and a lost report expires`() = runTest {
        val router = MessageRouter()
        val scope = TestScope(testScheduler)
        val m = RingManager(router, FakeRinger(), scope, selfId = "me"); m.start()
        router.dispatch(ringState("phone", true)); router.dispatch(ringState("phone", true))
        assertEquals(setOf("phone"), m.ringingPeers.value)
        router.dispatch(ringState("phone", false)); router.dispatch(ringState("phone", false))
        assertEquals(emptySet<String>(), m.ringingPeers.value)
        router.dispatch(ringState("tablet", true))                // report of "stopped" never arrives
        scope.advanceTimeBy(RingManager.PEER_RINGING_EXPIRY_MS + 1); scope.testScheduler.runCurrent()
        assertEquals(emptySet<String>(), m.ringingPeers.value)
        m.shutdown()
    }
}
