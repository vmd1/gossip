package dev.vmd1.gossip.features.screenmirror

import android.content.Context
import dev.vmd1.gossip.util.Log

/**
 * Keeps the phone awake during screen-off mirroring, and — crucially — **always** puts the setting it changes back,
 * even if the session that changed it never reaches its own teardown.
 *
 * Screen-off mirroring powers the panel truly off (`SET_DISPLAY_POWER`, a real black AMOLED screen — see
 * [ScreenBridge.panelOff]), which on its own leaves the device to Doze after the screen-off timeout, and ColorOS then
 * throttles rendering so the mirror stutters. The one thing that prevents that is a long `screen_off_timeout`: the
 * legacy display-power path turns the panel off without telling PowerManager the screen slept, so the device stays
 * Awake and composites at full rate as long as the user-activity timeout hasn't fired. A wake lock does **not** work
 * here — ColorOS drops this app's screen wake locks (`ProxyButDropTypes`) — so the timeout is the lever.
 *
 * `screen_off_timeout` is a persisted setting, so a huge value left behind would stop the phone ever sleeping on its
 * own. The app can be killed mid-mirror and Shizuku can drop, so per-session in-memory restore isn't enough. This
 * guard records the user's real timeout once (behind a marker in [SharedPreferences]), restores it when a session
 * ends, and on app start / Shizuku reconnect restores it if a session left it changed ([recoverIfOrphaned]).
 *
 * All writes go through Shizuku (shell UID); call [keepAwake]/[restore] off the main thread.
 */
object ScreenOffGuard {
    private const val TAG = "ScreenMirror"
    private const val PREFS = "screen_off_mirroring"
    private const val KEY_ACTIVE = "keepawake_active"
    private const val KEY_SAVED_TIMEOUT = "saved_screen_off_timeout"
    private const val LONG_TIMEOUT_MS = (24L * 60 * 60 * 1000).toString() // effectively "until we restore it"

    private val lock = Any()

    /** Captures the current screen-off timeout (once) and raises it, so the device won't sleep (and Doze) mid-mirror. */
    fun keepAwake(context: Context) {
        synchronized(lock) {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            if (!prefs.getBoolean(KEY_ACTIVE, false)) {
                prefs.edit()
                    .putString(KEY_SAVED_TIMEOUT, settingsGet("screen_off_timeout"))
                    .putBoolean(KEY_ACTIVE, true).commit() // commit, not apply: on disk before we change the setting
            }
            runCatching { shellExec("settings", "put", "system", "screen_off_timeout", LONG_TIMEOUT_MS) }
                .onFailure { Log.w(TAG, "couldn't raise screen-off timeout: ${it.message}") }
        }
    }

    /** Restores the captured timeout and clears the marker. A no-op when nothing is marked. */
    fun restore(context: Context) {
        synchronized(lock) {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            if (!prefs.getBoolean(KEY_ACTIVE, false)) return
            runCatching {
                prefs.getString(KEY_SAVED_TIMEOUT, null)?.let { shellExec("settings", "put", "system", "screen_off_timeout", it) }
            }.onFailure { Log.w(TAG, "couldn't restore screen-off timeout: ${it.message}"); return }
            prefs.edit().remove(KEY_SAVED_TIMEOUT).putBoolean(KEY_ACTIVE, false).commit()
            Log.i(TAG, "restored screen-off timeout after screen-off mirroring")
        }
    }

    /**
     * Restores a timeout left raised by a session that didn't clean up (app killed mid-mirror, Shizuku down at
     * teardown). Call on app start and when Shizuku connects — but only when no screen-off mirror is running, so it
     * never fights a live session. Does **not** touch display power: a panel left off is recovered by a power-button
     * press (sending a sleep/wake key here could blank the screen while the user is holding the phone).
     */
    fun recoverIfOrphaned(context: Context) {
        if (context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_ACTIVE, false)) {
            Log.i(TAG, "recovering screen-off timeout left raised by a previous session")
            restore(context)
        }
    }

    private fun settingsGet(key: String): String? =
        runCatching {
            val p = ShizukuShell.exec("settings", "get", "system", key)
            val out = p.inputStream.bufferedReader().readText().trim()
            p.waitFor()
            out.takeIf { it.isNotEmpty() && it != "null" }
        }.getOrNull()

    private fun shellExec(vararg cmd: String) {
        val p = ShizukuShell.exec(*cmd)
        p.inputStream.bufferedReader().readText()
        p.waitFor()
    }
}
