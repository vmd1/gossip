package dev.vmd1.gossip.transport

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * This device's relay preferences (plain [SharedPreferences], never sent over the wire). Off by default: until the user
 * turns it on, the app opens no relay socket at all. Mirrors the Mac's `RelaySettings`.
 */
class RelaySettings(private val prefs: SharedPreferences) {
    private val _enabled = MutableStateFlow(prefs.getBoolean(KEY_ENABLED, false))
    private val _customUrl = MutableStateFlow(prefs.getString(KEY_CUSTOM_URL, "") ?: "")

    val enabled: StateFlow<Boolean> = _enabled
    val customUrl: StateFlow<String> = _customUrl

    @Synchronized
    fun setEnabled(value: Boolean) {
        prefs.edit().putBoolean(KEY_ENABLED, value).apply()
        _enabled.value = value
    }

    @Synchronized
    fun setCustomUrl(value: String) {
        prefs.edit().putString(KEY_CUSTOM_URL, value).apply()
        _customUrl.value = value
    }

    /**
     * What the engine should be configured with: the custom address, else the relay the directory names, else the built-in
     * default. A `null` origin only when the custom address is invalid (a typo must not silently send traffic elsewhere).
     * [awaitingDirectory] (first run, polling on, nothing cached, first poll not finished; bounded by the 10 s request
     * timeout) holds the relay back rather than connecting to the default just before the directory names another relay.
     */
    fun configuration(directoryOrigin: String? = null, directoryIsFresh: Boolean = false, awaitingDirectory: Boolean = false): Configuration {
        val resolution = RelayEndpointPolicy.resolve(_customUrl.value, directoryOrigin, directoryIsFresh) ?: return Configuration(false, null)
        if (awaitingDirectory && resolution.source == RelayEndpointPolicy.Source.DEFAULT) return Configuration(false, null)
        return if (_enabled.value) Configuration(true, resolution.origin) else Configuration(false, null)
    }

    data class Configuration(val enabled: Boolean, val origin: String?)

    companion object {
        private const val PREFS_NAME = "relay_settings"
        private const val KEY_ENABLED = "relay_enabled"
        private const val KEY_CUSTOM_URL = "relay_custom_url"

        @Volatile private var instance: RelaySettings? = null

        fun getInstance(context: Context): RelaySettings = instance ?: synchronized(this) {
            instance ?: RelaySettings(
                context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            ).also { instance = it }
        }
    }
}

/**
 * Persists the mesh topic secret and epoch the engine reports (`TopicChanged`). The secret decides who can find this
 * mesh on the relay, so it lives in an [EncryptedSharedPreferences] file (Android Keystore master key) like the identity
 * keys. It is never logged.
 */
class RelayTopicStore(private val prefs: SharedPreferences) {
    class Topic(val secret: ByteArray, val epoch: Long)

    fun load(): Topic? {
        val encoded = prefs.getString(KEY_SECRET, null) ?: return null
        val secret = runCatching { java.util.Base64.getDecoder().decode(encoded) }.getOrNull() ?: return null
        if (secret.size != 32 || !prefs.contains(KEY_EPOCH)) return null
        return Topic(secret, prefs.getLong(KEY_EPOCH, 0))
    }

    /** Synchronous commit: the secret must be on disk before the engine moves on. */
    fun save(secret: ByteArray, epoch: Long): Boolean = prefs.edit()
        .putString(KEY_SECRET, java.util.Base64.getEncoder().encodeToString(secret))
        .putLong(KEY_EPOCH, epoch)
        .commit()

    companion object {
        private const val PREFS_FILE = "connect_relay_topic"
        private const val KEY_SECRET = "topic_secret"
        private const val KEY_EPOCH = "topic_epoch"

        @Volatile private var instance: RelayTopicStore? = null

        fun getInstance(context: Context): RelayTopicStore = instance ?: synchronized(this) {
            instance ?: build(context.applicationContext).also { instance = it }
        }

        private fun build(context: Context): RelayTopicStore {
            val masterKey = MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build()
            val prefs = EncryptedSharedPreferences.create(
                context, PREFS_FILE, masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )
            return RelayTopicStore(prefs)
        }
    }
}
