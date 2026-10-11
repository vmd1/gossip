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

/** `notification.sync` payload (android -> mesh, broadcast): the ids of every notification this phone is currently
 *  mirroring, so a receiver can drop any mirrored copy that is no longer in the list (a `notification.removed` that
 *  was lost to a disconnect or race). Sent on every fresh connection and every 60 s. Receivers only act on
 *  notifications they have held for a few seconds, so a snapshot that races a newer `notification.posted` never
 *  removes it. */
@Serializable
data class NotificationSyncPayload(val ids: List<String>) {
    fun toEnvelope(senderId: String): Envelope = Envelope(
        type = MessageType.NOTIFICATION_SYNC,
        senderId = senderId,
        broadcast = true,
        payload = Json.encodeToJsonElement(serializer(), this).jsonObject
    )

    companion object {
        /** A phone with more active notifications than this skips the sync rather than send a huge message;
         *  receivers then simply keep what they have. */
        const val MAX_IDS = 200
        private val json = Json { ignoreUnknownKeys = true }

        fun fromPayload(payload: JsonObject): NotificationSyncPayload =
            json.decodeFromJsonElement(serializer(), payload)
    }
}

/** `notification.reply` payload (mac -> android / android -> android).
 *
 *  [attemptId] uniquely identifies this *reply attempt*, not the notification (`id` is
 *  reused across distinct replies to the same notification, so it can't serve as a
 *  dedupe key on its own). The receiver keys its recently-handled cache off this field —
 *  see `NotificationListenerImpl.handleReply` — so a duplicate delivery (retry, relay
 *  race, dedupe-cache eviction) can't fire the same real-world reply twice. */
@Serializable
data class NotificationReplyPayload(
    val id: String,
    val text: String,
    val attemptId: String
) {
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
