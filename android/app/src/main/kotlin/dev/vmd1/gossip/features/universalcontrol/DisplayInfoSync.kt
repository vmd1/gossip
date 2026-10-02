package dev.vmd1.gossip.features.universalcontrol

import android.content.Context
import android.hardware.display.DisplayManager
import android.util.DisplayMetrics
import android.util.Log
import android.view.Display
import dev.vmd1.gossip.protocol.Envelope
import dev.vmd1.gossip.protocol.MessageType
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject

private const val TAG = "DisplayInfoSync"

/** The display's logical, rotation-applied pixel size — what the Mac's layout window draws. */
data class DisplaySize(val width: Int, val height: Int, val rotation: Int)

/**
 * Implements `display.info` (see `schema/message-types.md`): broadcasts this device's display size so a
 * Mac can draw an accurately shaped card in its Universal Control layout before any control session exists.
 *
 * **Reconciled**: [resync] is called on every newly connected peer and every 60s (from
 * `SyncForegroundService`), so a dropped send or a rotation that happened while disconnected self-heals.
 * Receivers treat it as last-write-wins per sender, so a repeat is a no-op.
 */
class DisplayInfoSync(
    private val deviceId: String,
    private val send: suspend (Envelope) -> Unit,
    private val scope: CoroutineScope,
    private val readSize: () -> DisplaySize?
) {
    fun resync() {
        val size = readSize() ?: return
        val envelope = Envelope(
            type = MessageType.DISPLAY_INFO,
            senderId = deviceId,
            broadcast = true,
            payload = payload(size)
        )
        scope.launch { runCatching { send(envelope) }.onFailure { Log.w(TAG, "Failed to send display.info", it) } }
    }

    companion object {
        fun payload(size: DisplaySize) = buildJsonObject {
            put("width", JsonPrimitive(size.width))
            put("height", JsonPrimitive(size.height))
            put("rotation", JsonPrimitive(size.rotation))
        }

        @Suppress("DEPRECATION")
        fun readFromSystem(context: Context): DisplaySize? {
            val display = context.getSystemService(DisplayManager::class.java)?.getDisplay(Display.DEFAULT_DISPLAY) ?: return null
            val metrics = DisplayMetrics()
            display.getRealMetrics(metrics)
            if (metrics.widthPixels <= 0 || metrics.heightPixels <= 0) return null
            return DisplaySize(metrics.widthPixels, metrics.heightPixels, display.rotation)
        }
    }
}
