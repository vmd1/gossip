package dev.vmd1.gossip.features.notifications

import dev.vmd1.gossip.protocol.MessageType
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

        val envelope = payload.toEnvelope(senderId = "device-android")

        assertEquals(MessageType.NOTIFICATION_POSTED, envelope.type)
        assertEquals("device-android", envelope.senderId)
        assertTrue(envelope.broadcast)
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
        val envelope = payload.toEnvelope(senderId = "device-android")

        val decoded = dev.vmd1.gossip.protocol.Envelope.decode(envelope.encode())

        assertEquals("notification.posted", decoded.type)
        assertNull(decoded.recipientId)
        assertTrue(decoded.broadcast)
        assertTrue(decoded.payload.toString().contains("notif-2"))
    }

    @Test
    fun `notification removed envelope carries id and correct type`() {
        val envelope = NotificationRemovedPayload(id = "notif-3").toEnvelope(senderId = "device-android")
        assertEquals(MessageType.NOTIFICATION_REMOVED, envelope.type)
        assertTrue(envelope.broadcast)
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
        ).toEnvelope(senderId = "device-mac")

        // Build a notification.reply payload with the core (the way both apps now do), then accept it the way
        // NotificationListenerImpl.handleReply does.
        val payload = uniffi.gossip_ffi.notificationReplyPayload("notif-4", "On my way", "attempt-1")
        val guard = uniffi.gossip_ffi.ReplyGuard()
        val parsed = guard.accept(payload)!!
        assertEquals("notif-4", parsed.notificationId)
        assertEquals("On my way", parsed.text)
        assertEquals(null, guard.accept(payload))   // the same attempt is acted on once
        assertTrue(envelope.type == MessageType.NOTIFICATION_POSTED) // sanity: unrelated envelope untouched
    }
}
