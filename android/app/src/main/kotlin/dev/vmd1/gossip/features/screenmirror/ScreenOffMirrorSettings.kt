package dev.vmd1.gossip.features.screenmirror

import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * The per-device "Screen-off mirroring" switch (off by default). When on, a whole-screen mirror keeps running with the
 * phone's own panel powered off (see [ScreenBridge.panelOff] and [ScreenOffGuard]); the phone sleeps and locks again
 * when mirroring ends. App-window mirrors are unaffected.
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
