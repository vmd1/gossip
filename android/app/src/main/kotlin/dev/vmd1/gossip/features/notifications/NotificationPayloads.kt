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

/** A button on the source notification (not its reply action), pressed from another device with `notification.action`. */
@Serializable
data class NotificationActionInfo(val index: Int, val title: String)

/** A live notification (progress, timer, call): what receivers draw instead of static text. */
@Serializable
data class NotificationLive(
    /** `"progress"`, `"timer"` or `"call"`. */
    val kind: String,
    val progress: Int? = null,
    val max: Int? = null,
    val indeterminate: Boolean? = null,
    /** Epoch ms the chronometer counts from, for `timer` and `call`. */
    val chronometerBase: Long? = null
)

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
    /** The sender's or conversation's picture (the notification's large icon), 96x96 PNG. Optional; older peers ignore it. */
    val avatarBase64: String? = null,
    /** A big picture the notification carries (`BigPictureStyle`), JPEG at most 512 px on the long edge. */
    val pictureBase64: String? = null,
    /** The notification's own buttons other than reply, at most [MAX_ACTIONS]. */
    val actions: List<NotificationActionInfo>? = null,
    /** The reply action's suggested replies, at most [MAX_SMART_REPLIES]. */
    val smartReplies: List<String>? = null,
    val live: NotificationLive? = null
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
        private val json = Json { encodeDefaults = true; explicitNulls = false }
        const val MAX_ACTIONS = 3
        const val MAX_SMART_REPLIES = 3
        const val MAX_PICTURE_BASE64_CHARS = 400_000
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

/** `notification.action` payload (any device -> the phone that posted the notification, targeted): press the button at
 *  [index] of the source notification's actions. [attemptId] (a UUID per press) is the de-duplication key, because
 *  pressing a button can have effects outside the app (answer a call, archive an email), so a duplicate delivery must
 *  not press it twice. */
@Serializable
data class NotificationActionPayload(val id: String, val index: Int, val attemptId: String) {
    companion object {
        private val json = Json { ignoreUnknownKeys = true }

        fun fromPayload(payload: JsonObject): NotificationActionPayload =
            json.decodeFromJsonElement(serializer(), payload)
    }
}

/** Remembers the last [limit] attempt ids so a repeated one is acted on once: a bounded recently-handled cache, the same
 *  pattern as `media.command`'s `commandId` and `notification.reply`'s `attemptId`. */
class RecentAttempts(private val limit: Int = 128) {
    private val seen = LinkedHashSet<String>()

    /** `true` the first time [attemptId] is offered, `false` for every repeat. */
    @Synchronized
    fun firstTime(attemptId: String): Boolean {
        if (!seen.add(attemptId)) return false
        while (seen.size > limit) seen.remove(seen.first())
        return true
    }
}
