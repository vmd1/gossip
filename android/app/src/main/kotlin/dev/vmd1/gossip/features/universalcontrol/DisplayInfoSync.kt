package dev.vmd1.gossip.features.universalcontrol

import android.content.Context
import android.hardware.display.DisplayManager
import android.os.Handler
import android.os.Looper
import android.util.DisplayMetrics
import android.view.Display
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import uniffi.gossip_ffi.DisplayInfo
import uniffi.gossip_ffi.displayPayload
import uniffi.gossip_ffi.displaySlot

/** The display's logical, rotation-applied pixel size — what the Mac's layout window draws. */
data class DisplaySize(val width: Int, val height: Int, val rotation: Int)

/**
 * Publishes this device's display size as the `control.display` state slot (see `schema/message-types.md` and
 * `docs/plans/state-sync.md`), so a Mac can draw an accurately shaped card in its Universal Control layout before any
 * control session exists. The core sends the slot to every device that connects later and repairs it periodically, so a
 * dropped send or a rotation that happened while disconnected heals itself; [publish] is called at start and on every
 * display change (rotation, resize) and is a no-op when the size is unchanged.
 */
class DisplayInfoSync(
    private val setState: (slot: String, value: JsonElement?) -> Unit,
    private val readSize: () -> DisplaySize?
) {
    private var listener: DisplayManager.DisplayListener? = null

    /** Publishes the current size (the core ignores an unchanged one). Nothing is published if it cannot be read. */
    fun publish() {
        val size = readSize() ?: return
        val value = displayPayload(DisplayInfo(size.width.toUInt(), size.height.toUInt(), size.rotation.coerceIn(0, 3).toUByte()))
        setState(displaySlot(), Json.parseToJsonElement(value))
    }

    /** Publishes now and again whenever the display changes (a rotation, a fold). */
    fun start(context: Context) {
        publish()
        val manager = context.getSystemService(DisplayManager::class.java) ?: return
        val l = object : DisplayManager.DisplayListener {
            override fun onDisplayAdded(displayId: Int) = Unit
            override fun onDisplayRemoved(displayId: Int) = Unit
            override fun onDisplayChanged(displayId: Int) { if (displayId == Display.DEFAULT_DISPLAY) publish() }
        }
        manager.registerDisplayListener(l, Handler(Looper.getMainLooper()))
        listener = l
    }

    fun stop(context: Context) {
        listener?.let { context.getSystemService(DisplayManager::class.java)?.unregisterDisplayListener(it) }
        listener = null
    }

    companion object {
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
