package dev.vmd1.gossip.features.universalcontrol

import android.util.Log
import java.util.TreeSet

/** What a Universal Control session needs to turn the Mac's input into input on this device. */
interface InputBackend {
    /** [ControlBackendKind] raw value reported in the display info. */
    val kind: Int
    /** The cursor enters through [edge], [position] (0..65535) along it. Idempotent: re-entering repositions. */
    fun enter(edge: ControlEdge, position: Int, display: ControlDisplayInfo)
    /** The cursor left: release anything held and remove the virtual devices (so the cursor disappears). Idempotent. */
    fun leave()
    fun mouseMove(dx: Int, dy: Int)
    fun buttons(mask: Int)
    fun scroll(dx: Int, dy: Int)
    fun key(usage: Int, down: Boolean, modifiers: Int)
    fun text(text: String)
    fun close()
}

object ControlBackendKind { const val UHID = 0; const val TOUCH_OVERLAY = 1 }

/**
 * Backend A: a virtual USB-HID mouse and keyboard created through the bundled scrcpy server's UHID control
 * messages (`/dev/uhid` at shell UID). Android treats them as a real mouse and keyboard: it draws its own
 * cursor, delivers hover/click/scroll, real key events with meta state, and hides the soft keyboard.
 *
 * Verified live on the Samsung SM-T500 (Android 12, enforcing SELinux): devices appear in `dumpsys input`,
 * hover / button / wheel / key events reach an app (see `InputProbeActivity`), and destroying them removes
 * the cursor. [write] sends one framed scrcpy control message. Not thread-safe: drive it from one thread.
 */
class UhidInputBackend(
    private val write: (ByteArray) -> Unit,
    private val sleep: (Long) -> Unit = { Thread.sleep(it) },
    private val compensator: PointerAccelCompensator? = PointerAccelCompensator(),
) : InputBackend {
    override val kind = ControlBackendKind.UHID

    private var created = false
    private var buttonMask = 0
    private val pressed = TreeSet<Int>()
    private var heldModifiers = 0
    private var wheelRemainderY = 0
    private var wheelRemainderX = 0

    override fun enter(edge: ControlEdge, position: Int, display: ControlDisplayInfo) {
        if (!created) {
            write(HidReports.create(HidReports.MOUSE_ID, "Gossip Mouse", HidReports.MOUSE_DESCRIPTOR))
            write(HidReports.create(HidReports.KEYBOARD_ID, "Gossip Keyboard", HidReports.KEYBOARD_DESCRIPTOR))
            created = true
            sleep(DEVICE_SETTLE_MS) // events written before Android has opened the new evdev node are lost
        }
        releaseAll()
        // Slam into the top-left corner (a clamped, therefore exact, position), then walk to the entry point.
        // A single report after a pause is not accelerated, which is what makes this precise.
        compensator?.reset()
        write(HidReports.input(HidReports.MOUSE_ID, HidReports.mouseReport(0, -32767, -32767)))
        sleep(ACCEL_SETTLE_MS)
        val frac = position.coerceIn(0, 65535) / 65535.0
        val x = when (edge) { ControlEdge.LEFT -> 0; ControlEdge.RIGHT -> display.width - 1; else -> (frac * (display.width - 1)).toInt() }
        val y = when (edge) { ControlEdge.TOP -> 0; ControlEdge.BOTTOM -> display.height - 1; else -> (frac * (display.height - 1)).toInt() }
        if (x != 0 || y != 0) write(HidReports.input(HidReports.MOUSE_ID, HidReports.mouseReport(0, x, y)))
        sleep(ACCEL_SETTLE_MS)
    }

    override fun leave() {
        if (!created) return
        releaseAll()
        write(HidReports.destroy(HidReports.MOUSE_ID))
        write(HidReports.destroy(HidReports.KEYBOARD_ID))
        created = false
    }

    private fun releaseAll() {
        if (buttonMask != 0) { buttonMask = 0; write(HidReports.input(HidReports.MOUSE_ID, HidReports.mouseReport(0, 0, 0))) }
        if (pressed.isNotEmpty() || heldModifiers != 0) {
            pressed.clear(); heldModifiers = 0
            write(HidReports.input(HidReports.KEYBOARD_ID, HidReports.keyboardReport(0, emptyList())))
        }
    }

    override fun mouseMove(dx: Int, dy: Int) {
        if (!created) return
        val (cx, cy) = compensator?.compensate(System.nanoTime(), dx, dy) ?: (dx to dy)
        if (cx == 0 && cy == 0) return
        write(HidReports.input(HidReports.MOUSE_ID, HidReports.mouseReport(buttonMask, cx, cy)))
    }

    override fun buttons(mask: Int) {
        if (!created || mask == buttonMask) return // idempotent: a repeated state is not a new event
        buttonMask = mask and 0x1f
        write(HidReports.input(HidReports.MOUSE_ID, HidReports.mouseReport(buttonMask, 0, 0)))
    }

    override fun scroll(dx: Int, dy: Int) {
        if (!created) return
        wheelRemainderY += dy; wheelRemainderX += dx
        val ny = wheelRemainderY / 120; val nx = wheelRemainderX / 120
        wheelRemainderY -= ny * 120; wheelRemainderX -= nx * 120
        if (ny != 0 || nx != 0) write(HidReports.input(HidReports.MOUSE_ID, HidReports.mouseReport(buttonMask, 0, 0, ny, nx)))
    }

    override fun key(usage: Int, down: Boolean, modifiers: Int) {
        if (!created) return
        val changed = if (usage in 4..0x65) (if (down) pressed.add(usage) else pressed.remove(usage)) else true
        if (!changed && modifiers == heldModifiers) return
        heldModifiers = modifiers and 0xff
        write(HidReports.input(HidReports.KEYBOARD_ID, HidReports.keyboardReport(heldModifiers, pressed)))
    }

    override fun text(text: String) {
        if (text.isEmpty()) return
        // INJECT_TEXT only types what a key map can produce (ASCII); anything else goes through the clipboard.
        if (text.all { it.code in 0x20..0x7e }) write(HidReports.injectText(text)) else write(HidReports.pasteText(text))
    }

    override fun close() { runCatching { leave() } }

    private companion object {
        const val TAG = "UhidInput"
        const val DEVICE_SETTLE_MS = 300L
        const val ACCEL_SETTLE_MS = 130L
    }
}

/**
 * Android applies pointer acceleration to a relative mouse (`VelocityControl`: scale 1.0 below ~500
 * counts/s, rising to 3.0 at 3000 counts/s), on top of the acceleration macOS already applied to the deltas
 * we receive, so the cursor on the device would travel further than the Mac's integrated position (drift).
 * This divides each report by an estimate of that scale from our own recent send rate. Measured live on the
 * SM-T500: without it a 600-count move at 600-1200 counts/s lands 25-95% too far; a single report after a
 * pause is exact. It is an approximation (Android's velocity tracker is not reproduced exactly), so the Mac
 * also re-slams on enter and relies on edge clamping.
 */
class PointerAccelCompensator(
    private val low: Double = 500.0,
    private val high: Double = 3000.0,
    private val maxScale: Double = 3.0,
    private val windowNanos: Long = 80_000_000L,
) {
    private class Sample(val t: Long, val d: Double)
    private val samples = ArrayDeque<Sample>()
    private var remX = 0.0
    private var remY = 0.0

    fun reset() { samples.clear(); remX = 0.0; remY = 0.0 }

    fun scale(speed: Double): Double = when {
        speed <= low -> 1.0
        speed >= high -> maxScale
        else -> 1.0 + (speed - low) * (maxScale - 1.0) / (high - low)
    }

    /** Returns the integer report to send for an intended move of ([dx], [dy]) at time [nowNanos]. */
    fun compensate(nowNanos: Long, dx: Int, dy: Int): Pair<Int, Int> {
        while (samples.isNotEmpty() && nowNanos - samples.first().t > windowNanos) samples.removeFirst()
        val dist = Math.hypot(dx.toDouble(), dy.toDouble())
        val windowCounts = samples.sumOf { it.d } + dist
        val span = maxOf((nowNanos - (samples.firstOrNull()?.t ?: nowNanos)).toDouble(), 8_000_000.0) / 1e9
        val s = scale(windowCounts / span)
        val fx = dx / s + remX; val fy = dy / s + remY
        val ox = Math.round(fx).toInt(); val oy = Math.round(fy).toInt()
        remX = fx - ox; remY = fy - oy
        samples.addLast(Sample(nowNanos, Math.hypot(ox.toDouble(), oy.toDouble())))
        return ox to oy
    }
}
