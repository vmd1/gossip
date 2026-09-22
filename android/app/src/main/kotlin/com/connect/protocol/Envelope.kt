package com.connect.protocol

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import java.util.UUID

/**
 * The wire-protocol envelope shared by every message exchanged between a
 * Connect device pair, matching the schema unit's contract:
 *
 * ```json
 * {"v":1,"id":"uuid-v4","type":"namespace.action","senderId":"device-uuid",
 *  "recipientId":"device-uuid-or-null","broadcast":false,
 *  "ts":1732300000000,"payload":{}}
 * ```
 */
@Serializable
data class Envelope(
    val v: Int = 1,
    val id: String = UUID.randomUUID().toString(),
    val type: String,
    val senderId: String,
    val recipientId: String? = null,
    val broadcast: Boolean = false,
    val ts: Long = System.currentTimeMillis(),
    val payload: JsonObject = JsonObject(emptyMap())
) {
    companion object {
        val json = Json {
            ignoreUnknownKeys = true
            encodeDefaults = true
        }

        fun decode(bytes: ByteArray): Envelope = json.decodeFromString(serializer(), String(bytes, Charsets.UTF_8))
    }

    fun encode(): ByteArray = json.encodeToString(serializer(), this).toByteArray(Charsets.UTF_8)
}

/** Well-known `type` namespaces/actions used by this unit. */
object MessageType {
    const val HANDSHAKE_HELLO = "handshake.hello"
    const val HANDSHAKE_ACK = "handshake.ack"
    const val PRESENCE_ONLINE = "presence.online"
    const val PRESENCE_OFFLINE = "presence.offline"
    const val PRESENCE_HEARTBEAT = "presence.heartbeat"

    // File transfer (Wave 2, unit 9 / M6). See schema/message-types.md.
    const val FILE_OFFER = "file.offer"
    const val FILE_ACCEPT = "file.accept"
    const val FILE_REJECT = "file.reject"
    const val FILE_COMPLETE = "file.complete"

    /** Local convention (not a standalone binary-carrying type): a `file.chunk`
     *  metadata envelope is always immediately followed by exactly one raw
     *  binary frame of `byteLength` bytes. See schema/message-types.md. */
    const val FILE_CHUNK = "file.chunk"

    const val NOTIFICATION_POSTED = "notification.posted"
    const val NOTIFICATION_REMOVED = "notification.removed"
    const val NOTIFICATION_REPLY = "notification.reply"
    const val DND_UPDATE = "dnd.update"
    const val DND_SET = "dnd.set"
    const val CLIPBOARD_UPDATE = "clipboard.update"
}

/** Device types advertised in handshake payloads and pairing metadata. */
enum class DeviceType(val wireValue: String) {
    MAC("mac"),
    ANDROID_PHONE("android-phone"),
    ANDROID_TABLET("android-tablet");

    companion object {
        fun fromWire(value: String): DeviceType = entries.firstOrNull { it.wireValue == value } ?: ANDROID_PHONE
    }
}

fun JsonElement.orEmptyObject(): JsonObject = this as? JsonObject ?: JsonObject(emptyMap())
