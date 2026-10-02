package dev.vmd1.gossip.features.notifications

import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * Which apps' notifications this **phone** forwards to its paired devices (Settings → Notifications →
 * Apps). Every app is allowed by default, so a newly installed app forwards without any setup; only
 * the apps the user switched off are stored (as a set of package names). Local to the device and
 * never sent over the wire — it filters at the source, in [NotificationListenerImpl].
 */
class NotificationForwardSettings internal constructor(private val prefs: SharedPreferences) {
    private val _blocked = MutableStateFlow(prefs.getStringSet(KEY_BLOCKED, emptySet()).orEmpty().toSet())

    /** Package names whose notifications are *not* forwarded; collect to react to changes. */
    val blocked: StateFlow<Set<String>> = _blocked

    fun isAllowed(packageName: String): Boolean = packageName !in _blocked.value

    @Synchronized
    fun setAllowed(packageName: String, allowed: Boolean) {
        val next = if (allowed) _blocked.value - packageName else _blocked.value + packageName
        if (next == _blocked.value) return
        _blocked.value = next
        prefs.edit().putStringSet(KEY_BLOCKED, next).apply()
    }

    @Synchronized
    fun setAllAllowed() {
        if (_blocked.value.isEmpty()) return
        _blocked.value = emptySet()
        prefs.edit().remove(KEY_BLOCKED).apply()
    }

    companion object {
        private const val PREFS_NAME = "notification_forward_settings"
        private const val KEY_BLOCKED = "blocked_packages"

        @Volatile private var instance: NotificationForwardSettings? = null

        fun getInstance(context: Context): NotificationForwardSettings = instance ?: synchronized(this) {
            instance ?: NotificationForwardSettings(
                context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            ).also { instance = it }
        }
    }
}
