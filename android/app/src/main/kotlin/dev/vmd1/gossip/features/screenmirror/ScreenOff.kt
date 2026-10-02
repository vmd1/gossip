package dev.vmd1.gossip.features.screenmirror

import android.util.Log

/**
 * Puts the device's screen to sleep when a mirroring session ends, by sending the sleep key through Shizuku
 * (shell UID can inject key events; a normal app cannot).
 *
 * **`KEYCODE_SLEEP`, not `KEYCODE_POWER`:** the power key *toggles* — pressing it when the screen is already
 * off (the user turned it off, or it timed out) would switch it back **on**. `KEYCODE_SLEEP` only ever turns
 * the screen off, so it is safe to send unconditionally.
 */
internal object ScreenOff {
    private const val TAG = "ScreenMirror"
    internal val COMMAND = arrayOf("input", "keyevent", "KEYCODE_SLEEP")

    /** Fire-and-forget on its own thread; a no-op if Shizuku isn't running. */
    fun sleep() {
        Thread({
            runCatching { ShizukuShell.exec(*COMMAND).waitFor() }
                .onSuccess { Log.i(TAG, "screen put to sleep after mirroring (exit $it)") }
                .onFailure { Log.w(TAG, "couldn't put the screen to sleep: ${it.message}") }
        }, "screen-off").apply { isDaemon = true }.start()
    }
}
