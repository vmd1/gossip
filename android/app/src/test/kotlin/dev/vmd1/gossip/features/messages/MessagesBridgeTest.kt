package dev.vmd1.gossip.features.messages

import dev.vmd1.gossip.protocol.Envelope
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MessagesBridgeTest {
    private class FakeBackend : MessagesBackend {
        var permission = true
        val sends = mutableListOf<Pair<String, String>>()
        var failWith: MessagesBackend.Failure? = null
        override fun hasPermission() = permission
        override fun threads(limit: Int) = listOf(MessageThread("1", "+15551234567", "Ann", "hi", 100L, false, 2)).take(limit)
        override fun history(threadId: String, limit: Int, before: Long?) =
            if (threadId == "1") listOf(ChatMessage("m2", 200L, true, "yo"), ChatMessage("m1", 100L, false, "hi")) else emptyList()
        override fun send(address: String, body: String): MessagesBackend.Failure? { sends += address to body; return failWith }
        var contactList: List<Contact>? = (1..300).map { Contact("c$it", "Person $it", listOf("+1555000$it")) }
        override fun contacts() = contactList
        override fun summary() = MessagesBackend.Summary(200L, 2, 1)
    }

    private val backend = FakeBackend()
    private val sent = mutableListOf<Envelope>()
    private val states = mutableListOf<JsonObject?>()
    private var enabled = true

    private fun bridge() = MessagesBridge(
        selfId = "phone", scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined), backend = backend,
        send = { sent += it }, publishState = { states += it }, isEnabled = { enabled },
    )

    private fun env(type: String, vararg fields: Pair<String, Any>) = Envelope(
        type = type, senderId = "mac", recipientId = "phone",
        payload = buildJsonObject {
            for ((k, v) in fields) put(k, if (v is Number) JsonPrimitive(v) else JsonPrimitive(v.toString()))
        }
    )

    @Test fun `threads request is answered and repeatable`() {
        val b = bridge()
        val req = env(MessagesBridge.THREADS_REQUEST, "requestId" to "r1")
        b.handle(req); b.handle(req)
        assertEquals(2, sent.size)
        assertEquals(sent[0].payload, sent[1].payload)
        assertEquals("r1", sent[0].payload["requestId"]!!.jsonPrimitive.content)
        assertEquals("mac", sent[0].recipientId)
        val thread = (sent[0].payload["threads"] as JsonArray)[0] as JsonObject
        assertEquals("Ann", thread["name"]!!.jsonPrimitive.content)
    }

    @Test fun `history returns messages for a thread`() {
        bridge().handle(env(MessagesBridge.HISTORY_REQUEST, "requestId" to "r", "threadId" to "1"))
        assertEquals(2, (sent[0].payload["messages"] as JsonArray).size)
    }

    @Test fun `a duplicate send texts once and repeats the result`() {
        val b = bridge()
        val req = env(MessagesBridge.SEND, "attemptId" to "a1", "address" to "+15551234567", "body" to "hello")
        b.handle(req); b.handle(req); b.handle(req)
        assertEquals(1, backend.sends.size)
        assertEquals(3, sent.size)
        assertTrue(sent.all { it.payload["ok"]!!.jsonPrimitive.content == "true" })
    }

    @Test fun `a failed send is remembered and not retried by a duplicate`() {
        backend.failWith = MessagesBackend.Failure.FAILED
        val b = bridge()
        val req = env(MessagesBridge.SEND, "attemptId" to "a2", "address" to "+15551234567", "body" to "hello")
        b.handle(req)
        backend.failWith = null
        b.handle(req)
        assertEquals(1, backend.sends.size)
        assertEquals("failed", sent[1].payload["reason"]!!.jsonPrimitive.content)
    }

    @Test fun `different attempts both send`() {
        val b = bridge()
        b.handle(env(MessagesBridge.SEND, "attemptId" to "x", "address" to "+15551234567", "body" to "one"))
        b.handle(env(MessagesBridge.SEND, "attemptId" to "y", "address" to "+15551234567", "body" to "one"))
        assertEquals(2, backend.sends.size)
    }

    @Test fun `disabled or unpermitted answers with a reason and does nothing`() {
        enabled = false
        val b = bridge()
        b.handle(env(MessagesBridge.THREADS_REQUEST, "requestId" to "r"))
        b.handle(env(MessagesBridge.SEND, "attemptId" to "z", "address" to "+15551234567", "body" to "hi"))
        assertEquals("disabled", sent[0].payload["reason"]!!.jsonPrimitive.content)
        assertEquals("disabled", sent[1].payload["reason"]!!.jsonPrimitive.content)
        assertTrue(backend.sends.isEmpty())
        enabled = true; backend.permission = false
        b.handle(env(MessagesBridge.HISTORY_REQUEST, "requestId" to "r", "threadId" to "1"))
        assertEquals("no_permission", sent[2].payload["reason"]!!.jsonPrimitive.content)
    }

    @Test fun `malformed requests are ignored`() {
        val b = bridge()
        b.handle(env(MessagesBridge.THREADS_REQUEST))
        b.handle(env(MessagesBridge.SEND, "address" to "+15551234567", "body" to "no attempt id"))
        b.handle(env(MessagesBridge.SEND, "attemptId" to "q", "address" to "+15551234567", "body" to "x".repeat(5000)))
        assertTrue(backend.sends.isEmpty())
        assertEquals("invalid", sent.last().payload["reason"]!!.jsonPrimitive.content)
    }

    @Test fun `state is published only when it changes and cleared when off`() {
        val b = bridge()
        b.publish(); b.publish()
        assertEquals(1, states.size)
        assertEquals("2", states[0]!!["unread"]!!.jsonPrimitive.content)
        enabled = false
        b.publish()
        assertNull(states.last())
        assertFalse(states.size == 1)
    }

    @Test fun `contacts are sent in pages with a digest`() {
        bridge().handle(env(MessagesBridge.CONTACTS_REQUEST, "requestId" to "c1"))
        assertEquals(2, sent.size)
        assertEquals(sent[0].payload["digest"], sent[1].payload["digest"])
        assertEquals("0", sent[0].payload["page"]!!.jsonPrimitive.content)
        assertEquals("2", sent[0].payload["pages"]!!.jsonPrimitive.content)
        assertEquals(250 + 50, sent.sumOf { (it.payload["contacts"] as JsonArray).size })
    }

    @Test fun `an unchanged digest sends no contacts and a repeat is harmless`() {
        val b = bridge()
        b.handle(env(MessagesBridge.CONTACTS_REQUEST, "requestId" to "c1"))
        val digest = sent[0].payload["digest"]!!.jsonPrimitive.content
        sent.clear()
        val again = env(MessagesBridge.CONTACTS_REQUEST, "requestId" to "c2", "haveDigest" to digest)
        b.handle(again); b.handle(again)
        assertEquals(2, sent.size)
        assertTrue(sent.all { it.payload["unchanged"]!!.jsonPrimitive.content == "true" && it.payload["contacts"] == null })
    }

    @Test fun `contacts without the permission are reported`() {
        backend.contactList = null
        bridge().handle(env(MessagesBridge.CONTACTS_REQUEST, "requestId" to "c"))
        assertEquals("no_contacts_permission", sent[0].payload["reason"]!!.jsonPrimitive.content)
    }
}
