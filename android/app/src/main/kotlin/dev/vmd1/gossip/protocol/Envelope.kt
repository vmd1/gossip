package dev.vmd1.gossip.protocol

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
 *  "recipientId":"device-uuid-or-null","broadcast":false,"ttl":8,
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
    /** Hop budget for flood-forwarding across the mesh: set to [DEFAULT_TTL] by the
     *  originating sender, decremented by 1 at every relaying hop (a device forwarding
     *  an envelope it did not originate), dropped (not forwarded further) once it
     *  reaches 0. See `docs/wire-protocol.md`'s "Multi-hop relay" section. */
    val ttl: Int = DEFAULT_TTL,
    /** When `true`, this envelope's metadata is immediately followed on the wire by a
     *  second, raw (non-envelope) Noise-encrypted frame — the "large binary payload"
     *  convention in `docs/wire-protocol.md` (e.g. clipboard image sync). Relayed
     *  hop-by-hop atomically alongside the envelope itself: a relaying device always
     *  forwards the metadata and its raw frame together, never the metadata alone. See
     *  [TransportManager]'s receive loop. */
    val hasRawFollowup: Boolean = false,
    val ts: Long = System.currentTimeMillis(),
    val payload: JsonObject = JsonObject(emptyMap())
) {
    companion object {
        val json = Json {
            ignoreUnknownKeys = true
            encodeDefaults = true
        }

        /** Default hop budget for an originating send — generous relative to any
         *  realistically-sized mesh of a handful of devices. */
        const val DEFAULT_TTL = 8

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
    const val SCREEN_START = "screen.start"
    const val SCREEN_STOP = "screen.stop"
    const val SCREEN_READY = "screen.ready"
    const val SCREEN_ERROR = "screen.error"

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
    const val NOTIFICATION_DISMISS = "notification.dismiss"
    const val DND_UPDATE = "dnd.update"
    const val DND_SET = "dnd.set"
    const val CLIPBOARD_UPDATE = "clipboard.update"
    const val TRUST_ROSTER_UPDATE = "trust.roster_update"
    const val TRUST_REVOKE = "trust.revoke"
    const val LOCK_ON_LEAVE_CONFIG = "lock_on_leave.config"
    const val HOTSPOT_STATE_UPDATE = "hotspot.state_update"
    const val DEVICE_RING = "device.ring"
    const val DEVICE_RING_STATE = "device.ring_state"
    const val BATTERY_UPDATE = "battery.update"
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
