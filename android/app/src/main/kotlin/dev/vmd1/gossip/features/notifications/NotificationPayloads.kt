package dev.vmd1.gossip.features.notifications

import dev.vmd1.gossip.protocol.Envelope
import dev.vmd1.gossip.protocol.MessageType
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject

/** Bundle extra key set (to `true`) on every notification [NotificationMirrorReceiver]
 *  posts locally to mirror a peer's notification. [NotificationListenerImpl] must check
 *  this and skip re-mirroring it — otherwise a phone mirroring a tablet's notification
 *  would immediately re-detect its own mirrored copy as "a new local notification" and
 *  broadcast it right back out, ping-ponging (and duplicating) it around the mesh
 *  forever. This is a distinct, more general guard than the one exclusion
 *  `NotificationListenerImpl` already had (skipping only its own persistent foreground
 *  "Gossip is running" notification by exact package+id) — it must apply regardless of
 *  package/id, since this class posts under this app's own package but must never be
 *  re-mirrored. */
const val EXTRA_IS_MIRROR = "dev.vmd1.gossip.app.isMirroredNotification"

/** `notification.posted` payload (android -> mac). See `schema/message-types.md`. */
@Serializable
data class NotificationPostedPayload(
    val id: String,
    val appPackage: String,
    val appName: String,
    val title: String,
    val body: String,
    val iconBase64: String? = null,
    val hasReplyAction: Boolean,
    val timestamp: Long
) {
    /** Broadcast (not targeted): every other trusted device in the mesh — Macs *and*
     *  other Android devices (phones/tablets) — should mirror this notification, not
     *  just whichever single peer this device happened to be tracking as "the" one. */
    fun toEnvelope(senderId: String): Envelope = Envelope(
        type = MessageType.NOTIFICATION_POSTED,
        senderId = senderId,
        broadcast = true,
        payload = json.encodeToJsonElement(serializer(), this).jsonObject
    )

    companion object {
        private val json = Json { encodeDefaults = true }
    }
}

/** `notification.removed` payload (android -> mesh, broadcast). */
@Serializable
data class NotificationRemovedPayload(val id: String) {
    fun toEnvelope(senderId: String): Envelope = Envelope(
        type = MessageType.NOTIFICATION_REMOVED,
        senderId = senderId,
        broadcast = true,
        payload = Json.encodeToJsonElement(serializer(), this).jsonObject
    )
}

/** `notification.reply` payload (mac -> android). */
@Serializable
data class NotificationReplyPayload(val id: String, val text: String) {
    companion object {
        private val json = Json { ignoreUnknownKeys = true }

        fun fromPayload(payload: JsonObject): NotificationReplyPayload =
            json.decodeFromJsonElement(serializer(), payload)
    }
}

/** `notification.dismiss` payload (mac -> android): the user dismissed the mirrored
 *  notification on the Mac, so the original on Android should be cleared too. */
@Serializable
data class NotificationDismissPayload(val id: String) {
    companion object {
        private val json = Json { ignoreUnknownKeys = true }

        fun fromPayload(payload: JsonObject): NotificationDismissPayload =
            json.decodeFromJsonElement(serializer(), payload)
    }
}
