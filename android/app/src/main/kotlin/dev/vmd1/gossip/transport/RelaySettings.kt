package dev.vmd1.gossip.transport

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import uniffi.gossip_ffi.RelayConfig
import uniffi.gossip_ffi.relayConfigNextChangedAt
import uniffi.gossip_ffi.relayConfigSupersedes

/**
 * This device's relay preferences (plain [SharedPreferences], never sent over the wire). Off by default: until the user
 * turns it on, the app opens no relay socket at all. Mirrors the Mac's `RelaySettings`.
 */
class RelaySettings(private val prefs: SharedPreferences, private val now: () -> Long = System::currentTimeMillis) {
    private val _enabled = MutableStateFlow(prefs.getBoolean(KEY_ENABLED, false))
    private val _customUrl = MutableStateFlow(prefs.getString(KEY_CUSTOM_URL, "") ?: "")

    val enabled: StateFlow<Boolean> = _enabled
    val customUrl: StateFlow<String> = _customUrl

    /**
     * When the user last edited these settings (ms since the epoch; 0 = never). The newest edit wins across the mesh
     * (`desktop/core/src/features/relay_config.rs`); adopting a peer's choice keeps the peer's timestamp.
     */
    @Volatile var changedAt: Long = prefs.getLong(KEY_CHANGED_AT, 0L)
        private set

    /** Called after a local edit or an adoption, so the transport can publish the `relay.config` slot. */
    @Volatile var onChange: ((RelayConfig) -> Unit)? = null

    /** What the mesh shares: the on/off choice and the custom address (null when unset). */
    val config: RelayConfig
        get() = RelayConfig(_enabled.value, _customUrl.value.ifEmpty { null }, changedAt)

    /** A user edit: stamps the change so it propagates, then publishes it. */
    fun setEnabled(value: Boolean) {
        val cb = synchronized(this) {
            if (value == _enabled.value) return
            prefs.edit().putBoolean(KEY_ENABLED, value).apply()
            _enabled.value = value
            stamp()
        }
        cb()
    }

    fun setCustomUrl(value: String) {
        val cb = synchronized(this) {
            if (value == _customUrl.value) return
            prefs.edit().putString(KEY_CUSTOM_URL, value).apply()
            _customUrl.value = value
            stamp()
        }
        cb()
    }

    private fun stamp(): () -> Unit {
        changedAt = relayConfigNextChangedAt(now(), changedAt)
        prefs.edit().putLong(KEY_CHANGED_AT, changedAt).apply()
        val snapshot = config
        return { onChange?.invoke(snapshot) }
    }

    /**
     * Adopts a newer choice from a paired device. Keeps the peer's timestamp (so re-applying it, or hearing it echoed back,
     * changes nothing) and never bumps [changedAt] itself. Returns whether anything changed.
     */
    fun adopt(incoming: RelayConfig): Boolean {
        val snapshot = synchronized(this) {
            if (!relayConfigSupersedes(incoming, config)) return false
            val url = incoming.customUrl ?: ""
            prefs.edit().putBoolean(KEY_ENABLED, incoming.enabled).putString(KEY_CUSTOM_URL, url)
                .putLong(KEY_CHANGED_AT, incoming.changedAt).apply()
            changedAt = incoming.changedAt
            _customUrl.value = url
            _enabled.value = incoming.enabled
            config
        }
        onChange?.invoke(snapshot)
        return true
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
        private const val KEY_CHANGED_AT = "relay_changed_at"

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
