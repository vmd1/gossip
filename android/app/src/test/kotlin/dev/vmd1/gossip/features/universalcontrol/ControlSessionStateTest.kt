package dev.vmd1.gossip.features.universalcontrol

import dev.vmd1.gossip.protocol.Envelope
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

class ControlSessionStateTest {
    private class FakeSession(override val sessionId: String, val failStart: Boolean, val onEnded: () -> Unit) : ControlSessionHandle {
        @Volatile var started = 0
        @Volatile var closed = 0
        override fun start(): ControlSessionHandle.Ready {
            started++
            if (failStart) error("boom")
            return ControlSessionHandle.Ready(4321, ControlDisplayInfo(2000, 1200, 1, 0), "uhid")
        }
        override fun close() { closed++; onEnded() }
    }

    private val sent = CopyOnWriteArrayList<Envelope>()
    private val sessions = CopyOnWriteArrayList<FakeSession>()
    private var shizuku = true
    private var failStart = false
    private var enabled = true
    private val secretB64 = java.util.Base64.getEncoder().encodeToString(ByteArray(32) { it.toByte() })

    private fun state() = ControlSessionState(
        selfId = "tablet", scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined),
        shizukuReady = { shizuku }, send = { sent.add(it) },
        sessionFactory = { id, _, onEnded -> FakeSession(id, failStart, onEnded).also { sessions.add(it) } },
        isEnabled = { enabled }, warn = { _, _ -> },
    )

    private fun start(id: String?, secret: String? = secretB64) = Envelope(
        type = "control.session_start", senderId = "mac", recipientId = "tablet", ttl = 0,
        payload = buildJsonObject {
            id?.let { put("sessionId", JsonPrimitive(it)) }; secret?.let { put("secret", JsonPrimitive(it)) }
        }
    )
    private fun end(id: String) = Envelope(type = "control.end", senderId = "mac", recipientId = "tablet", ttl = 0,
        payload = buildJsonObject { put("sessionId", JsonPrimitive(id)) })

    private fun awaitSent(n: Int) {
        val deadline = System.currentTimeMillis() + 3000
        while (sent.size < n && System.currentTimeMillis() < deadline) Thread.sleep(10)
    }

    @Test fun startLaunchesOnceAndRepliesReadyTargetedWithTtlZero() {
        val s = state(); s.onSessionStart(start("a")); awaitSent(1)
        assertEquals(1, sessions.size)
        val ready = sent[0]
        assertEquals("control.ready", ready.type); assertEquals("mac", ready.recipientId); assertEquals(0, ready.ttl)
        assertEquals(4321, ready.payload["port"]!!.jsonPrimitive.content.toInt())
        assertEquals("uhid", ready.payload["backend"]!!.jsonPrimitive.content)
        assertEquals("1200", ready.payload["height"]!!.jsonPrimitive.content)
    }

    @Test fun duplicateStartResendsReadyWithoutRelaunching() {
        val s = state(); s.onSessionStart(start("a")); awaitSent(1)
        s.onSessionStart(start("a")); awaitSent(2)
        assertEquals(1, sessions.size); assertEquals(1, sessions[0].started); assertEquals(0, sessions[0].closed)
        assertEquals(2, sent.count { it.type == "control.ready" })
    }

    @Test fun endIsIdempotentAndAStaleStartCannotResurrectIt() {
        val s = state(); s.onSessionStart(start("a")); awaitSent(1)
        s.onEnd(end("other")); assertEquals("a", s.activeSessionId)
        s.onEnd(end("a")); s.onEnd(end("a"))
        Thread.sleep(100)
        assertNull(s.activeSessionId); assertEquals(1, sessions[0].closed)
        s.onSessionStart(start("a")) // delayed duplicate
        Thread.sleep(100)
        assertEquals(1, sessions.size)
    }

    @Test fun newSessionReplacesTheOldOne() {
        val s = state(); s.onSessionStart(start("a")); awaitSent(1)
        s.onSessionStart(start("b")); awaitSent(2)
        Thread.sleep(100)
        assertEquals("b", s.activeSessionId); assertEquals(1, sessions[0].closed)
        assertEquals("b", sent.last().payload["sessionId"]!!.jsonPrimitive.content)
    }

    @Test fun refusalsAnswerWithAnErrorAndStartNothing() {
        val s = state()
        enabled = false; s.onSessionStart(start("a")); awaitSent(1)
        assertEquals("feature_disabled", sent[0].payload["reason"]!!.jsonPrimitive.content)
        enabled = true; shizuku = false; s.onSessionStart(start("b")); awaitSent(2)
        assertEquals("shizuku_unavailable", sent[1].payload["reason"]!!.jsonPrimitive.content)
        shizuku = true; s.onSessionStart(start("c", secret = "AAAA")); awaitSent(3)
        assertEquals("bad_secret", sent[2].payload["reason"]!!.jsonPrimitive.content)
        assertTrue(sessions.isEmpty())
    }

    @Test fun failedStartReportsErrorAndClearsTheSession() {
        failStart = true
        val s = state(); s.onSessionStart(start("a")); awaitSent(1)
        assertEquals("control.error", sent[0].type)
        assertEquals("start_failed", sent[0].payload["reason"]!!.jsonPrimitive.content)
        assertNull(s.activeSessionId)
    }

    @Test fun sessionThatEndsByItselfTellsTheMac() {
        val s = state(); s.onSessionStart(start("a")); awaitSent(1)
        sessions[0].onEnded()
        awaitSent(2)
        assertEquals("control.end", sent[1].type); assertNull(s.activeSessionId)
    }
}
