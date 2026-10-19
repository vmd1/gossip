package dev.vmd1.gossip.features.screenmirror

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.nio.ByteBuffer

/**
 * Pure (no UI, no networking) pieces of the Android *viewer* for on-device screen mirroring: parsing the bridge's
 * messages and encoding scrcpy control messages. Mirrors the Mac's `ScrcpyBridgeProtocol.swift`; the bridge side is
 * [ScreenBridge] and the contract is `schema/message-types.md` (`screen.ready`).
 */
sealed class BridgeMessage {
    /** `0x00`: `u64 BE pts/flags` then Annex-B H.264. Flag bit 62 = config (SPS+PPS), bit 61 = key frame. */
    class Video(val flags: Long, val payload: ByteArray) : BridgeMessage() {
        val isConfig get() = flags and CONFIG_FLAG != 0L
        val isKeyFrame get() = flags and KEY_FRAME_FLAG != 0L
        /** The presentation timestamp in microseconds (the low 62 bits are pts, the top two are flags). */
        val ptsUs get() = flags and PTS_MASK
    }

    /** `0x01`: encoded frame size changed (rotation / `RESET_VIDEO`). */
    data class Size(val width: Int, val height: Int) : BridgeMessage()

    /** `0x02`: raw scrcpy device-message bytes. Ignored by the viewer. */
    class DeviceMessage(val data: ByteArray) : BridgeMessage()

    /** `0x03`: interleaved signed 16-bit little-endian PCM (only when the header announced audio). */
    class Audio(val pcm: ByteArray) : BridgeMessage()

    companion object {
        const val CONFIG_FLAG = 1L shl 62
        const val KEY_FRAME_FLAG = 1L shl 61
        const val PTS_MASK = (1L shl 61) - 1

        fun parse(data: ByteArray): BridgeMessage? {
            if (data.isEmpty()) return null
            val body = ByteBuffer.wrap(data, 1, data.size - 1)
            return when (data[0].toInt()) {
                0x00 -> if (body.remaining() >= 8) Video(body.long, ByteArray(body.remaining()).also { body.get(it) }) else null
                0x01 -> if (body.remaining() == 8) Size(body.int, body.int) else null
                0x02 -> DeviceMessage(ByteArray(body.remaining()).also { body.get(it) })
                0x03 -> if (body.remaining() > 8) {
                    body.long
                    Audio(ByteArray(body.remaining()).also { body.get(it) })
                } else null
                else -> null
            }
        }
    }
}

/** The text header the bridge sends right after the viewer authenticates. */
data class BridgeStreamHeader(
    val codec: String,
    val width: Int,
    val height: Int,
    val deviceName: String,
    val audioSampleRate: Int?,
    val audioChannels: Int?
) {
    companion object {
        fun parse(text: String): BridgeStreamHeader? = runCatching {
            val obj = Json.parseToJsonElement(text).jsonObject
            val audio = (obj["audio"] as? JsonObject)?.takeIf {
                it["codec"]?.jsonPrimitive?.content == "raw" && it["format"]?.jsonPrimitive?.content == "s16le"
            }
            val rate = audio?.get("sampleRate")?.jsonPrimitive?.int?.takeIf { it > 0 }
            val channels = audio?.get("channels")?.jsonPrimitive?.int?.takeIf { it in 1..2 }
            BridgeStreamHeader(
                codec = obj.getValue("codec").jsonPrimitive.content,
                width = obj.getValue("width").jsonPrimitive.int,
                height = obj.getValue("height").jsonPrimitive.int,
                deviceName = (obj["deviceName"] as? JsonPrimitive)?.content ?: "",
                audioSampleRate = if (rate != null && channels != null) rate else null,
                audioChannels = if (rate != null && channels != null) channels else null
            )
        }.getOrNull()
    }
}

/** Encoders for the scrcpy 4.1 control messages the viewer sends back (client → server). */
object ScrcpyControl {
    const val ACTION_DOWN = 0
    const val ACTION_UP = 1
    const val ACTION_MOVE = 2

    const val KEY_HOME = 3
    const val KEY_BACK = 4
    const val KEY_APP_SWITCH = 187

    /** `INJECT_TOUCH_EVENT` (type 2): action, pointerId u64, position (x,y u32 + screen w,h u16), pressure u16, buttons. */
    fun touch(action: Int, pointerId: Long, x: Int, y: Int, width: Int, height: Int): ByteArray =
        ByteBuffer.allocate(32).apply {
            put(2).put(action.toByte()).putLong(pointerId)
            putInt(x.coerceAtLeast(0)).putInt(y.coerceAtLeast(0))
            putShort(width.coerceIn(0, 0xffff).toShort()).putShort(height.coerceIn(0, 0xffff).toShort())
            putShort(if (action == ACTION_UP) 0 else 0xffff.toShort())
            putInt(0).putInt(0)
        }.array()

    /** `INJECT_KEYCODE` (type 0): action (0 down / 1 up), keycode, repeat, metastate. */
    fun keycode(code: Int, down: Boolean, metaState: Int = 0): ByteArray =
        ByteBuffer.allocate(14).apply {
            put(0).put(if (down) 0 else 1).putInt(code).putInt(0).putInt(metaState)
        }.array()

    /** Down + up as one write (two messages back to back). */
    fun keyPress(code: Int): ByteArray = keycode(code, true) + keycode(code, false)

    /** `INJECT_TEXT` (type 1): u32 length + UTF-8, truncated to the server's 300-byte limit without splitting a code point. */
    fun text(s: String): ByteArray? {
        var bytes = s.toByteArray()
        if (bytes.isEmpty()) return null
        if (bytes.size > 300) {
            var end = 300
            while (end > 0 && (bytes[end].toInt() and 0xC0) == 0x80) end--
            bytes = bytes.copyOf(end)
        }
        return ByteBuffer.allocate(5 + bytes.size).put(1).putInt(bytes.size).put(bytes).array()
    }

    /** `RESET_VIDEO` (type 17): the server re-emits size + config + a key frame. */
    val RESET_VIDEO = byteArrayOf(17)

    /** `EXPAND_NOTIFICATION_PANEL` (type 5). */
    val EXPAND_NOTIFICATIONS = byteArrayOf(5)
}
