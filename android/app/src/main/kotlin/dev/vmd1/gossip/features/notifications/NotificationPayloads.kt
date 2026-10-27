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
    val timestamp: Long,
    /** The sender's photo: the last message's person icon, else the notification's large icon. */
    val avatarBase64: String? = null,
    /** An attached image (BigPicture, or the last message's image when the listener may read it), downscaled. */
    val pictureBase64: String? = null,
    /** The notification's own buttons that need no typed input, by their index in `Notification.actions`. */
    val actions: List<NotificationActionInfo>? = null,
    /** Suggested one-tap replies: the app's own choices, then the system's smart replies. */
    val smartReplies: List<String>? = null,
    /** Set for an ongoing notification worth following live: a call, a timer, a delivery or download in progress. */
    val live: NotificationLiveInfo? = null
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

@Serializable
data class NotificationActionInfo(val index: Int, val title: String)

@Serializable
data class NotificationLiveInfo(
    val category: String? = null,
    val progress: Int? = null,
    val progressMax: Int? = null,
    val indeterminate: Boolean = false,
    /** `Notification.when` when the notification shows a chronometer counting from (or down to) it. */
    val chronometerBaseMs: Long? = null,
    val countDown: Boolean = false,
    /** Android 16's Live Updates (`FLAG_PROMOTED_ONGOING`). */
    val promoted: Boolean = false
) {
    companion object {
        private val liveCategories = setOf(
            android.app.Notification.CATEGORY_CALL, android.app.Notification.CATEGORY_NAVIGATION,
            android.app.Notification.CATEGORY_STOPWATCH, android.app.Notification.CATEGORY_ALARM,
            android.app.Notification.CATEGORY_PROGRESS
        )

        /** Whether a notification is worth following live, from its plain facts (kept free of Android objects for tests):
         *  promoted, showing progress or a chronometer, or a call/navigation/stopwatch/alarm. Plain persistent ones
         *  ("VPN on", "Shizuku running") are none of these, so they stay out. */
        fun qualifies(promoted: Boolean, category: String?, progressMax: Int, indeterminate: Boolean, chronometer: Boolean): Boolean =
            promoted || progressMax > 0 || indeterminate || chronometer || category in liveCategories
    }
}

/** Limits how often an ongoing notification is re-sent: progress and timers update many times a second, and a chronometer
 *  needs no updates at all (the Mac counts from its base). Sends when the text changed, progress moved by 5% or more,
 *  or 2 s passed since the last send. */
class LiveThrottle(private val minIntervalMs: Long = 2_000) {
    private data class Sent(val atMs: Long, val text: String, val progressPercent: Int)

    private val last = LinkedHashMap<String, Sent>()

    fun shouldSend(key: String, nowMs: Long, text: String, progress: Int?, progressMax: Int?): Boolean {
        val percent = if (progress != null && progressMax != null && progressMax > 0) progress * 100 / progressMax else -1
        val previous = last[key]
        val send = previous == null || previous.text != text || kotlin.math.abs(previous.progressPercent - percent) >= 5 ||
            nowMs - previous.atMs >= minIntervalMs
        if (send) {
            last[key] = Sent(nowMs, text, percent)
            if (last.size > 64) last.remove(last.keys.first())
        }
        return send
    }

    fun forget(key: String) { last.remove(key) }
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

/** The value of the `notification.active` state slot (android -> mesh, see `docs/plans/state-sync.md`): the ids of every
 *  notification the phone is currently mirroring, so a receiver can drop any mirrored copy that is no longer in the list
 *  (a `notification.removed` that was lost to a disconnect or race). Receivers only act on notifications they have held
 *  for a few seconds, so a snapshot that raced a newer `notification.posted` never removes it. */
@Serializable
data class NotificationSyncPayload(val ids: List<String>) {
    fun toJson(): JsonObject = Json.encodeToJsonElement(serializer(), this).jsonObject

    companion object {
        /** A phone with more active notifications than this reports nothing rather than send a huge list;
         *  receivers then simply keep what they have. */
        const val MAX_IDS = 200
        private val json = Json { ignoreUnknownKeys = true }

        fun fromJson(value: kotlinx.serialization.json.JsonElement): NotificationSyncPayload =
            json.decodeFromJsonElement(serializer(), value)
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
