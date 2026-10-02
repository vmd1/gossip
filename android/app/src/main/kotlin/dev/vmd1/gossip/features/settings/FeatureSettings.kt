package dev.vmd1.gossip.features.settings

import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * A feature the user can turn off on *this* device (Settings screen). Every feature is on by
 * default. Turning one off makes this device stop taking part in it entirely: outgoing messages
 * for it are never sent and incoming ones are dropped ([FeatureSettings.isMessageAllowed]), and
 * local triggers that don't go through messages (Lock-on-Leave's BLE trigger, the background
 * clipboard poll, hotspot GATT requests) are skipped.
 */
enum class Feature(val title: String, val detail: String, val messagePrefixes: List<String>) {
    CLIPBOARD("Clipboard", "Copy on one device, paste on another.", listOf("clipboard.")),
    DND("Do Not Disturb", "Keep Do Not Disturb in sync with your devices.", listOf("dnd.")),
    NOTIFICATIONS(
        "Notifications",
        "Phones share their notifications with your paired devices and let them reply; every device shows the ones it receives.",
        listOf("notification.")
    ),
    MEDIA("Media controls", "Share what's playing and let paired devices control it.", listOf("media.")),

    /** `screen.` is deliberately not a message prefix here: [dev.vmd1.gossip.features.screenmirror.ScreenMirrorState]
     *  gates it itself so a refused request still gets a `screen.error` answer instead of silence. */
    SCREEN_MIRRORING(
        "Screen mirroring",
        "Let your paired devices mirror and control this screen (needs Shizuku).",
        emptyList()
    ),
    LOCK_ON_LEAVE(
        "Lock on leave",
        "Lock a paired device when this phone walks out of range, or lock this one when a paired phone does.",
        listOf("lock_on_leave.")
    ),
    HOTSPOT("Instant Hotspot", "Share this phone's hotspot with paired devices, or request theirs.", listOf("hotspot.")),
    FIND_DEVICE("Find my device", "Let paired devices make this one ring so you can find it, and ring theirs.", listOf("device.")),
    BATTERY("Battery sync", "Share this device's battery level and get low-battery alerts for paired devices.", listOf("battery."));
}

/**
 * Per-device feature toggles, persisted in plain [SharedPreferences] (never sent over the wire —
 * each device decides for itself). Mirrors the Mac's `FeatureSettings`.
 */
class FeatureSettings internal constructor(private val prefs: SharedPreferences) {
    private val _disabled = MutableStateFlow(Feature.values().filter { !prefs.getBoolean(key(it), true) }.toSet())

    /** The set of currently disabled features; collect to react to changes. */
    val disabled: StateFlow<Set<Feature>> = _disabled

    fun isEnabled(feature: Feature): Boolean = feature !in _disabled.value

    @Synchronized
    fun setEnabled(feature: Feature, enabled: Boolean) {
        prefs.edit().putBoolean(key(feature), enabled).apply()
        _disabled.value = if (enabled) _disabled.value - feature else _disabled.value + feature
    }

    /** `false` when [type] belongs to a feature this device has turned off. Applied to both
     *  outgoing sends and incoming deliveries; relaying other devices' messages is unaffected. */
    fun isMessageAllowed(type: String): Boolean = featureForMessageType(type)?.let(::isEnabled) ?: true

    companion object {
        private const val PREFS_NAME = "feature_settings"

        private fun key(feature: Feature) = "feature_${feature.name.lowercase()}_enabled"

        /** The feature that owns an envelope `type`, if any (`handshake.`, `presence.`, `trust.`, `screen.` are unowned). */
        fun featureForMessageType(type: String): Feature? =
            Feature.values().firstOrNull { f -> f.messagePrefixes.any { type.startsWith(it) } }

        @Volatile private var instance: FeatureSettings? = null

        fun getInstance(context: Context): FeatureSettings = instance ?: synchronized(this) {
            instance ?: FeatureSettings(
                context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            ).also { instance = it }
        }
    }
}
