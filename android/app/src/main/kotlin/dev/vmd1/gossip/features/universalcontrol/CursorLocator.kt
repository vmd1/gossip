package dev.vmd1.gossip.features.universalcontrol

import dev.vmd1.gossip.features.screenmirror.ShizukuShell
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Reads where Android's own cursor really is. A relative mouse is accelerated by InputReader (1x below ~500
 * px/s up to 3x above 3000 px/s, depending on timing), so the Mac cannot know the true position from the
 * deltas it sent; this is the ground truth it corrects its model with.
 *
 * Source: the cursor is its own SurfaceFlinger layer (`Sprite#0`) whose `pos=` is the pointer position minus the
 * cursor image's hotspot. That offset is constant for a device, so it is measured once ([calibrate]) while the
 * pointer sits at a position we know exactly (the entry point). A read costs ~100 ms, which is why the Mac only
 * asks while it thinks the cursor is near an edge.
 */
class CursorLocator(private val dump: () -> String? = ::dumpCursorLayer) {
    @Volatile private var offsetX = 0f
    @Volatile private var offsetY = 0f
    @Volatile var calibrated = false
        private set

    /** Sprite position as reported by the system, or null if unavailable. */
    fun readSprite(): Pair<Float, Float>? = parse(dump())

    /** [known] is where the pointer exactly is right now, in display pixels. */
    fun calibrate(known: Pair<Int, Int>): Boolean {
        val s = readSprite() ?: return false
        offsetX = s.first - known.first
        offsetY = s.second - known.second
        calibrated = true
        return true
    }

    /** The pointer position in display pixels, or null if not calibrated or unreadable. */
    fun position(): Pair<Float, Float>? {
        if (!calibrated) return null
        val s = readSprite() ?: return null
        return Pair(s.first - offsetX, s.second - offsetY)
    }

    companion object {
        private const val COMMAND =
            "dumpsys SurfaceFlinger | grep -A8 'BufferStateLayer (Sprite' | grep -m1 -o 'pos=([0-9.,-]*)'"
        private val POS = Regex("""pos=\((-?[0-9.]+),(-?[0-9.]+)\)""")
        private val io = Executors.newCachedThreadPool { r -> Thread(r, "ctl-cursor-read").apply { isDaemon = true } }

        fun parse(text: String?): Pair<Float, Float>? {
            val m = POS.find(text ?: return null) ?: return null
            val x = m.groupValues[1].toFloatOrNull() ?: return null
            val y = m.groupValues[2].toFloatOrNull() ?: return null
            return Pair(x, y)
        }

        /** Runs the dump at shell UID through Shizuku; null on failure or after 1.5 s. */
        fun dumpCursorLayer(): String? {
            val process = runCatching { ShizukuShell.exec("sh", "-c", COMMAND) }.getOrNull() ?: return null
            val reader = io.submit<String> { process.inputStream.bufferedReader().readText() }
            return try { reader.get(1500, TimeUnit.MILLISECONDS) } catch (_: Exception) {
                reader.cancel(true); runCatching { process.destroy() }; null
            }
        }
    }
}
