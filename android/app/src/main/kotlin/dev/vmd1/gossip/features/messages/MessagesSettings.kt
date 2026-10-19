package dev.vmd1.gossip.features.messages

import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** The per-device Messages switch. **Off by default**: message text is only ever served to a paired Mac once the user turns it on here. */
class MessagesSettings(private val prefs: SharedPreferences) {
    private val _enabled = MutableStateFlow(prefs.getBoolean(KEY, false))
    val enabled: StateFlow<Boolean> = _enabled

    fun setEnabled(value: Boolean) {
        prefs.edit().putBoolean(KEY, value).apply()
        _enabled.value = value
    }

    companion object {
        private const val KEY = "messages_enabled"
        @Volatile private var instance: MessagesSettings? = null
        fun getInstance(context: Context): MessagesSettings = instance ?: synchronized(this) {
            instance ?: MessagesSettings(context.applicationContext.getSharedPreferences("messages_settings", Context.MODE_PRIVATE)).also { instance = it }
        }
    }
}
