package dev.vmd1.gossip.features.universalcontrol

import android.util.Log
import java.util.TreeSet

/** What a Universal Control session needs to turn the Mac's input into input on this device. */
interface InputBackend {
    /** [ControlBackendKind] raw value reported in the display info. */
    val kind: Int
    /** The cursor enters through [edge], [position] (0..65535) along it. Idempotent: re-entering repositions. */
    fun enter(edge: ControlEdge, position: Int, display: ControlDisplayInfo)
    /** The cursor left: release anything held. The virtual devices stay (a quick re-[enter] is then instant); see
     *  [destroyDevices]. Idempotent. */
    fun leave()
    /** Removes the virtual devices (so the cursor disappears and the soft keyboard may return). A no-op while the
     *  cursor is on the device or when there are none. The bridge calls it a while after [leave]. */
    fun destroyDevices()
    fun mouseMove(dx: Int, dy: Int)
    /** `MouseMove`s applied since the last [enter]; reported alongside the real cursor position. */
    val movesApplied: Long get() = 0
    /** Display-pixel position the pointer was put at by the last [enter] (exact), or null before any enter. */
    val entryPoint: Pair<Int, Int>? get() = null
    fun buttons(mask: Int)
    fun scroll(dx: Int, dy: Int)
    fun key(usage: Int, down: Boolean, modifiers: Int)
    fun text(text: String)
    /** Home / App Switcher / Notifications / Back. */
    fun action(action: ControlAction)
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
 * the cursor.
 *
 * **Drift:** Android applies its pointer acceleration to a relative mouse (scale 1.0 below ~500 counts/s up to
 * 3.0 at 3000), so the cursor travels 1.3x-2x further than the deltas sent (measured on the SM-T500). A single
 * report after a pause is exact, and the top-left slam on [enter] is exact (it clamps). A device-side inverse
 * was tried and rejected: the send-rate estimate is too noisy through the Shizuku relay, giving 0.45x-1.1x
 * (undershoot is worse than overshoot). Instead the Mac models the gain (`PointerRouter.pointerGain`), and
 * the device clamps at its edges, which re-synchronises the cursor whenever it is pushed into a wall.
 * [write] sends one framed scrcpy control message. Not thread-safe: drive it from one thread.
 */
class UhidInputBackend(
    private val write: (ByteArray) -> Unit,
    private val sleep: (Long) -> Unit = { Thread.sleep(it) },
) : InputBackend {
    override val kind = ControlBackendKind.UHID

    private var created = false
    /** True from [enter] until [leave]: the cursor is on this device. */
    private var inside = false
    private var buttonMask = 0
    private val pressed = TreeSet<Int>()
    private var heldModifiers = 0
    private var wheelRemainderY = 0
    private var wheelRemainderX = 0
    private val moves = java.util.concurrent.atomic.AtomicLong()
    @Volatile private var entered: Pair<Int, Int>? = null
    override val movesApplied: Long get() = moves.get()
    override val entryPoint: Pair<Int, Int>? get() = entered

    override fun enter(edge: ControlEdge, position: Int, display: ControlDisplayInfo) {
        if (!created) {
            write(HidReports.create(HidReports.MOUSE_ID, "Gossip Mouse", HidReports.MOUSE_DESCRIPTOR))
            write(HidReports.create(HidReports.KEYBOARD_ID, "Gossip Keyboard", HidReports.KEYBOARD_DESCRIPTOR))
            created = true
            sleep(DEVICE_SETTLE_MS) // events written before Android has opened the new evdev node are lost
        }
        inside = true
        releaseAll()
        // Slam into the top-left corner (a clamped, therefore exact, position), then walk to the entry point.
        // A single report after a pause is not accelerated, which is what makes this precise.
        write(HidReports.input(HidReports.MOUSE_ID, HidReports.mouseReport(0, -32767, -32767)))
        sleep(ACCEL_SETTLE_MS)
        val frac = position.coerceIn(0, 65535) / 65535.0
        val x = when (edge) { ControlEdge.LEFT -> 0; ControlEdge.RIGHT -> display.width - 1; else -> (frac * (display.width - 1)).toInt() }
        val y = when (edge) { ControlEdge.TOP -> 0; ControlEdge.BOTTOM -> display.height - 1; else -> (frac * (display.height - 1)).toInt() }
        if (x != 0 || y != 0) write(HidReports.input(HidReports.MOUSE_ID, HidReports.mouseReport(0, x, y)))
        sleep(ACCEL_SETTLE_MS)
        moves.set(0)
        entered = Pair(x, y)
    }

    override fun leave() {
        if (!created) return
        inside = false
        releaseAll()
    }

    override fun destroyDevices() {
        if (!created || inside) return
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
        if (dx == 0 && dy == 0) return
        write(HidReports.input(HidReports.MOUSE_ID, HidReports.mouseReport(buttonMask, dx, dy)))
        moves.incrementAndGet()
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

    override fun action(action: ControlAction) {
        when (action) {
            ControlAction.HOME -> write(HidReports.pressKeycode(KEYCODE_HOME))
            ControlAction.BACK -> write(HidReports.pressKeycode(KEYCODE_BACK))
            ControlAction.APP_SWITCH -> write(HidReports.pressKeycode(KEYCODE_APP_SWITCH))
            ControlAction.NOTIFICATIONS -> write(HidReports.expandNotifications())
        }
    }

    override fun close() { runCatching { leave(); destroyDevices() } }

    private companion object {
        const val TAG = "UhidInput"
        const val KEYCODE_HOME = 3
        const val KEYCODE_BACK = 4
        const val KEYCODE_APP_SWITCH = 187
        const val DEVICE_SETTLE_MS = 300L
        const val ACCEL_SETTLE_MS = 130L
    }
}
