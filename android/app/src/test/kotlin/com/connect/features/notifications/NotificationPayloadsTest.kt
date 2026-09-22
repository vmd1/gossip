package com.connect.features.notifications

import com.connect.protocol.MessageType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationPayloadsTest {
    @Test
    fun `notification posted envelope carries expected type and fields`() {
        val payload = NotificationPostedPayload(
            id = "notif-1",
            appPackage = "com.whatsapp",
            appName = "WhatsApp",
            title = "Jane Doe",
            body = "Running 5 min late",
            iconBase64 = null,
            hasReplyAction = true,
            timestamp = 1_732_300_000_000
        )

        val envelope = payload.toEnvelope(senderId = "device-android", recipientId = "device-mac")

        assertEquals(MessageType.NOTIFICATION_POSTED, envelope.type)
        assertEquals("device-android", envelope.senderId)
        assertEquals("device-mac", envelope.recipientId)
        assertEquals("notif-1", envelope.payload["id"]?.toString()?.trim('"'))
        assertEquals("true", envelope.payload["hasReplyAction"].toString())
    }

    @Test
    fun `notification posted envelope round trips through wire encode decode`() {
        val payload = NotificationPostedPayload(
            id = "notif-2",
            appPackage = "com.slack",
            appName = "Slack",
            title = "#general",
            body = "New message",
            iconBase64 = "aGVsbG8=",
            hasReplyAction = false,
            timestamp = 42
        )
        val envelope = payload.toEnvelope(senderId = "device-android", recipientId = null)

        val decoded = com.connect.protocol.Envelope.decode(envelope.encode())

        assertEquals("notification.posted", decoded.type)
        assertNull(decoded.recipientId)
        assertTrue(decoded.payload.toString().contains("notif-2"))
    }

    @Test
    fun `notification removed envelope carries id and correct type`() {
        val envelope = NotificationRemovedPayload(id = "notif-3").toEnvelope(senderId = "device-android", recipientId = "device-mac")
        assertEquals(MessageType.NOTIFICATION_REMOVED, envelope.type)
        assertEquals("notif-3", envelope.payload["id"]?.toString()?.trim('"'))
    }

    @Test
    fun `notification reply payload parses from a json object`() {
        val envelope = NotificationPostedPayload(
            id = "notif-4",
            appPackage = "com.whatsapp",
            appName = "WhatsApp",
            title = "Jane",
            body = "Hi",
            iconBase64 = null,
            hasReplyAction = true,
            timestamp = 1
        ).toEnvelope(senderId = "device-mac", recipientId = "device-android")

        // Build a notification.reply payload the way the Mac side would, then parse it
        // back the way NotificationListenerImpl.handleReply does.
        val replyEnvelope = com.connect.protocol.Envelope(
            type = MessageType.NOTIFICATION_REPLY,
            senderId = "device-mac",
            recipientId = "device-android",
            payload = kotlinx.serialization.json.Json.encodeToJsonElement(
                NotificationReplyPayload.serializer(),
                NotificationReplyPayload(id = "notif-4", text = "On my way")
            ).let { it as kotlinx.serialization.json.JsonObject }
        )

        val parsed = NotificationReplyPayload.fromPayload(replyEnvelope.payload)
        assertEquals("notif-4", parsed.id)
        assertEquals("On my way", parsed.text)
        assertTrue(envelope.type == MessageType.NOTIFICATION_POSTED) // sanity: unrelated envelope untouched
    }
}
