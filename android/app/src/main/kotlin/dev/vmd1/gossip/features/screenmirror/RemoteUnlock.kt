package dev.vmd1.gossip.features.screenmirror

import android.app.KeyguardManager
import android.content.Context
import android.content.SharedPreferences
import dev.vmd1.gossip.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * The per-device "Screen-off mirroring" switch (off by default). When on, a whole-screen mirror keeps running with the
 * phone's panel switched off (the session holds a wake lock and the scrcpy server powers the display down), the screen
 * really sleeps and locks only when mirroring ends, and a paired Mac may unlock a locked phone with `screen.unlock`.
 */
class ScreenOffMirrorSettings(private val prefs: SharedPreferences) {
    private val _enabled = MutableStateFlow(prefs.getBoolean(KEY, false))
    val enabled: StateFlow<Boolean> = _enabled

    fun setEnabled(value: Boolean) {
        prefs.edit().putBoolean(KEY, value).apply()
        _enabled.value = value
    }

    companion object {
        private const val KEY = "screen_off_mirroring_enabled"
        @Volatile private var instance: ScreenOffMirrorSettings? = null
        fun getInstance(context: Context): ScreenOffMirrorSettings = instance ?: synchronized(this) {
            instance ?: ScreenOffMirrorSettings(
                context.applicationContext.getSharedPreferences("screen_off_mirroring", Context.MODE_PRIVATE)
            ).also { instance = it }
        }
    }
}

/**
 * Unlocks the phone with a credential sent by the Mac (`screen.unlock`), by running [KeyguardUnlocker] at shell UID
 * through Shizuku. One attempt per call, never retried here: wrong attempts count toward the lockout.
 */
object RemoteUnlock {
    private const val TAG = "RemoteUnlock"

    /** A locked keyguard protected by a PIN, password or pattern. */
    fun isLocked(context: Context): Boolean {
        val km = context.getSystemService(KeyguardManager::class.java) ?: return false
        return km.isDeviceSecure && km.isKeyguardLocked
    }

    /**
     * Types [secret] on the lock screen and reports `ok`, `wrong` (typed but still locked), `no_bouncer` (the entry
     * screen didn't come up, so nothing was typed) or `failed`. Blocking; call off the main thread.
     */
    fun unlock(context: Context, secret: String): String {
        if (!isLocked(context)) return "ok"
        val started = android.os.SystemClock.elapsedRealtime()
        val line = try {
            val p = ShizukuShell.exec(
                "sh", "-c",
                "CLASSPATH=${context.applicationInfo.sourceDir} exec app_process / ${KeyguardUnlocker::class.java.name}"
            )
            p.outputStream.use { it.write((secret + "\n").toByteArray(Charsets.UTF_8)) }
            // The helper prints one line and exits. Shizuku's remote process doesn't support a timed waitFor (it
            // throws "process hasn't exited"), so a watchdog destroys a helper that hangs instead.
            val watchdog = Thread { try { Thread.sleep(20_000); p.destroy() } catch (_: InterruptedException) { } }
                .apply { isDaemon = true; start() }
            val out = p.inputStream.bufferedReader().readLine()
            watchdog.interrupt()
            runCatching { p.destroy() }
            out?.trim()
        } catch (t: Throwable) {
            Log.w(TAG, "unlock helper failed: ${t.message}")
            return "failed"
        }
        Log.i(TAG, "unlock helper: $line after ${android.os.SystemClock.elapsedRealtime() - started} ms")
        return when (line) {
            "typed" -> {
                // The keyguard takes a moment to go away after the last key.
                val deadline = System.currentTimeMillis() + 3_000
                while (System.currentTimeMillis() < deadline) {
                    if (!isLocked(context)) return "ok"
                    Thread.sleep(150)
                }
                "wrong"
            }
            "no_bouncer" -> "no_bouncer"
            else -> "failed"
        }
    }
}
