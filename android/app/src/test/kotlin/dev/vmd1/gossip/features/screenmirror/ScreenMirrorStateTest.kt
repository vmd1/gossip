package dev.vmd1.gossip.features.screenmirror

import dev.vmd1.gossip.protocol.Envelope
import dev.vmd1.gossip.protocol.MessageType
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

/** Start/stop idempotency + failure paths of [ScreenMirrorState], with a fake capture session. */
class ScreenMirrorStateTest {
    private class FakeSession(override val sessionId: String, val failStart: Boolean = false) : ScreenSession {
        @Volatile var started = 0
        @Volatile var closed = 0
        override fun start(): ScreenSession.Ready {
            started++
            if (failStart) error("boom")
            return ScreenSession.Ready(1234, "tok-$sessionId", 576, 1280, "h264")
        }
        override fun close() { closed++ }
    }

    private val sent = CopyOnWriteArrayList<Envelope>()
    private val sessions = CopyOnWriteArrayList<FakeSession>()
    private var shizuku = true
    private var failStart = false

    private fun state() = ScreenMirrorState(
        selfId = "phone",
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined),
        shizukuReady = { shizuku },
        send = { sent.add(it) },
        sessionFactory = { id, _, _ -> FakeSession(id, failStart).also { sessions.add(it) } },
        warn = { _, _ -> },
    )

    private fun env(type: String, sessionId: String? = null) = Envelope(
        type = type, senderId = "mac", recipientId = "phone",
        payload = buildJsonObject { sessionId?.let { put("sessionId", JsonPrimitive(it)) } }
    )

    private fun awaitSent(n: Int) {
        val end = System.currentTimeMillis() + 3000
        while (sent.size < n && System.currentTimeMillis() < end) Thread.sleep(10)
    }

    @Test fun startLaunchesOnceAndRepliesReady() {
        val s = state()
        s.onScreenStart(env(MessageType.SCREEN_START, "a"))
        awaitSent(1)
        assertEquals(1, sessions.size)
        assertEquals(MessageType.SCREEN_READY, sent[0].type)
        assertEquals("mac", sent[0].recipientId)
        assertEquals("tok-a", sent[0].payload["token"]!!.jsonPrimitive.content)
        assertTrue(s.isMirroring.value)
    }

    @Test fun duplicateStartDoesNotRelaunchButResendsReady() {
        val s = state()
        s.onScreenStart(env(MessageType.SCREEN_START, "a"))
        awaitSent(1)
        s.onScreenStart(env(MessageType.SCREEN_START, "a"))
        awaitSent(2)
        assertEquals(1, sessions.size)
        assertEquals(1, sessions[0].started)
        assertEquals(2, sent.count { it.type == MessageType.SCREEN_READY })
        assertEquals(0, sessions[0].closed)
    }

    @Test fun duplicateAndUnknownStopsAreNoOps() {
        val s = state()
        s.onScreenStart(env(MessageType.SCREEN_START, "a"))
        awaitSent(1)
        s.onScreenStop(env(MessageType.SCREEN_STOP, "other"))
        assertTrue(s.isMirroring.value)
        s.onScreenStop(env(MessageType.SCREEN_STOP, "a"))
        s.onScreenStop(env(MessageType.SCREEN_STOP, "a"))
        Thread.sleep(200)
        assertFalse(s.isMirroring.value)
        assertEquals(1, sessions[0].closed)
    }

    @Test fun lateDuplicateStartAfterStopDoesNotResurrect() {
        val s = state()
        s.onScreenStart(env(MessageType.SCREEN_START, "a"))
        awaitSent(1)
        s.onScreenStop(env(MessageType.SCREEN_STOP, "a"))
        s.onScreenStart(env(MessageType.SCREEN_START, "a"))
        Thread.sleep(200)
        assertEquals(1, sessions.size)
        assertFalse(s.isMirroring.value)
    }

    @Test fun stopBeforeStartIsRememberedToo() {
        val s = state()
        s.onScreenStop(env(MessageType.SCREEN_STOP, "a"))
        s.onScreenStart(env(MessageType.SCREEN_START, "a"))
        Thread.sleep(200)
        assertEquals(0, sessions.size)
    }

    @Test fun newSessionSupersedesOld() {
        val s = state()
        s.onScreenStart(env(MessageType.SCREEN_START, "a"))
        awaitSent(1)
        s.onScreenStart(env(MessageType.SCREEN_START, "b"))
        awaitSent(2)
        Thread.sleep(200)
        assertEquals(2, sessions.size)
        assertEquals(1, sessions[0].closed)
        assertEquals(0, sessions[1].closed)
        assertTrue(s.isMirroring.value)
    }

    @Test fun shizukuUnavailableRepliesError() {
        shizuku = false
        val s = state()
        s.onScreenStart(env(MessageType.SCREEN_START, "a"))
        awaitSent(1)
        assertEquals(MessageType.SCREEN_ERROR, sent[0].type)
        assertEquals("shizuku_unavailable", sent[0].payload["reason"]!!.jsonPrimitive.content)
        assertEquals(0, sessions.size)
        assertFalse(s.isMirroring.value)
    }

    @Test fun captureStartFailureRepliesErrorAndCleansUp() {
        failStart = true
        val s = state()
        s.onScreenStart(env(MessageType.SCREEN_START, "a"))
        awaitSent(1)
        assertEquals("capture_failed", sent[0].payload["reason"]!!.jsonPrimitive.content)
        assertEquals(1, sessions[0].closed)
        assertFalse(s.isMirroring.value)
    }

    @Test fun messagesWithoutSessionIdAreIgnored() {
        val s = state()
        s.onScreenStart(env(MessageType.SCREEN_START))
        Thread.sleep(100)
        assertEquals(0, sessions.size)
        assertFalse(s.isMirroring.value)
        s.onScreenStart(env(MessageType.SCREEN_START, "a"))
        awaitSent(1)
        s.onScreenStop(env(MessageType.SCREEN_STOP)) // no sessionId: must not end the active session
        assertTrue(s.isMirroring.value)
        assertEquals(0, sessions[0].closed)
    }
}
