package dev.vmd1.gossip.features.screenmirror

import android.content.Context
import android.content.SharedPreferences
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

    /** Android's own default screen-off timeout (60 s), written back when the real one couldn't be read. */
    internal const val DEFAULT_TIMEOUT_MS = "60000"

    /** Reads and writes `settings system`; Shizuku in the app, a fake in tests. */
    internal interface Settings {
        fun get(key: String): String?
        fun put(key: String, value: String)
    }

    private object ShizukuSettings : Settings {
        override fun get(key: String): String? = settingsGet(key)
        override fun put(key: String, value: String) = shellExec("settings", "put", "system", key, value)
    }

    private val lock = Any()

    /** The screen-off sessions that currently need the raised timeout. A new whole-screen mirror ends the previous one, so
     *  two can overlap briefly; the timeout is only put back when the last of them lets go. */
    private val holders = mutableSetOf<String>()

    /** Captures the current screen-off timeout (once) and raises it, so the device won't sleep (and Doze) mid-mirror. */
    fun keepAwake(context: Context, owner: String) = keepAwake(prefs(context), ShizukuSettings, owner)

    internal fun keepAwake(prefs: SharedPreferences, settings: Settings, owner: String) {
        synchronized(lock) {
            holders.add(owner)
            if (!prefs.getBoolean(KEY_ACTIVE, false)) {
                // A failed read must not leave the phone on the long timeout for good: remember Android's default instead.
                val current = runCatching { settings.get("screen_off_timeout") }.getOrNull() ?: DEFAULT_TIMEOUT_MS
                prefs.edit().putString(KEY_SAVED_TIMEOUT, current).putBoolean(KEY_ACTIVE, true).commit() // on disk before we change the setting
            }
            runCatching { settings.put("screen_off_timeout", LONG_TIMEOUT_MS) }
                .onFailure { note( "couldn't raise screen-off timeout: ${it.message}") }
        }
    }

    /** [owner] no longer needs the raised timeout. Returns `true` when no screen-off session is left, i.e. the caller is the
     *  last one and should power the panel back on and call [restore]. */
    fun release(owner: String): Boolean = synchronized(lock) { holders.remove(owner); holders.isEmpty() }

    /** Whether any screen-off session is still live (other than none). */
    fun anyActive(): Boolean = synchronized(lock) { holders.isNotEmpty() }

    /** Restores the captured timeout and clears the marker. A no-op when nothing is marked or a session still holds it. */
    fun restore(context: Context) = restore(prefs(context), ShizukuSettings)

    internal fun restore(prefs: SharedPreferences, settings: Settings) {
        synchronized(lock) {
            if (holders.isNotEmpty()) return
            if (!prefs.getBoolean(KEY_ACTIVE, false)) return
            runCatching {
                prefs.getString(KEY_SAVED_TIMEOUT, null)?.let { settings.put("screen_off_timeout", it) }
            }.onFailure { note( "couldn't restore screen-off timeout: ${it.message}"); return }
            prefs.edit().remove(KEY_SAVED_TIMEOUT).putBoolean(KEY_ACTIVE, false).commit()
            note( "restored screen-off timeout after screen-off mirroring")
        }
    }

    /**
     * Restores a timeout left raised by a session that didn't clean up (app killed mid-mirror, Shizuku down at
     * teardown). Call on app start and when Shizuku connects. It does nothing while a screen-off mirror is live (the marker
     * is also set during one), so it never fights a live session. Does **not** touch display power: a panel left off is
     * recovered by a power-button press (sending a sleep/wake key here could blank the screen while the user is holding
     * the phone).
     */
    fun recoverIfOrphaned(context: Context) = recoverIfOrphaned(prefs(context), ShizukuSettings)

    internal fun recoverIfOrphaned(prefs: SharedPreferences, settings: Settings) {
        synchronized(lock) {
            if (holders.isEmpty() && prefs.getBoolean(KEY_ACTIVE, false)) {
                note( "recovering screen-off timeout left raised by a previous session")
                restore(prefs, settings)
            }
        }
    }

    /** Test hook: forget every holder (a fresh process has none). */
    internal fun resetForTest() = synchronized(lock) { holders.clear() }

    /** Logging must never break the restore (and the Android log isn't available in unit tests). */
    private fun note(msg: String) { runCatching { Log.i(TAG, msg) } }

    private fun prefs(context: Context): SharedPreferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

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
