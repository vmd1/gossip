package com.connect.crypto

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.connect.protocol.DeviceType
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.util.Base64

/** One row of the `TrustedDevices` table: deviceId -> publicKey -> metadata. */
data class TrustedDevice(
    val deviceId: String,
    val publicKey: ByteArray,
    val deviceName: String,
    val deviceType: DeviceType,
    val addedAt: Long,
    /** User-entered fallback address (e.g. a Tailscale IP) to dial directly when normal
     *  on-LAN discovery can't reach this peer — see `TransportManager`'s fallback-dial
     *  loop, driven from `SyncForegroundService`. Manual because there is no discovery
     *  mechanism that works off-LAN; `null`/blank means "not configured." */
    val fallbackHost: String? = null,
    /** For a row where [deviceType] is [DeviceType.MAC]: whether this device should tell
     *  that Mac to lock its screen when this device leaves BLE range (`lock_on_leave.config`
     *  in `schema/message-types.md`). Meaningless for a phone/tablet row — only Macs are
     *  ever locked. Local-only bookkeeping so the UI toggle reflects saved state across
     *  restarts; the Mac is the one that actually acts on it, via its own BLE proximity
     *  observation, not a message this device sends it repeatedly. */
    val lockOnLeaveEnabled: Boolean = false
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is TrustedDevice) return false
        return deviceId == other.deviceId &&
            publicKey.contentEquals(other.publicKey) &&
            deviceName == other.deviceName &&
            deviceType == other.deviceType &&
            addedAt == other.addedAt &&
            fallbackHost == other.fallbackHost &&
            lockOnLeaveEnabled == other.lockOnLeaveEnabled
    }

    override fun hashCode(): Int = deviceId.hashCode()
}

@Serializable
private data class TrustedDeviceRow(
    val deviceId: String,
    val publicKeyBase64: String,
    val deviceName: String,
    val deviceType: String,
    val addedAt: Long,
    val fallbackHost: String? = null,
    val lockOnLeaveEnabled: Boolean = false
)

/**
 * Persists the `TrustedDevices` table (deviceId -> publicKey -> metadata) rather than a
 * single hardcoded "paired device" field. The long-term goal is a multi-device
 * ecosystem (several phones/tablets/Macs trusting each other); modelling this as a
 * table from day one avoids a protocol/storage rewrite later, even though a v1
 * install will typically only ever populate one row.
 *
 * Backed by a [SharedPreferences] instance — normally [EncryptedSharedPreferences] via
 * [getInstance], but the primary constructor takes the interface directly so tests can
 * supply an in-memory fake without touching the Android Keystore.
 */
class TrustedDevicesStore internal constructor(private val prefs: SharedPreferences) {

    @Synchronized
    fun addDevice(device: TrustedDevice) {
        val row = TrustedDeviceRow(
            deviceId = device.deviceId,
            publicKeyBase64 = Base64.getEncoder().encodeToString(device.publicKey),
            deviceName = device.deviceName,
            deviceType = device.deviceType.wireValue,
            addedAt = device.addedAt,
            fallbackHost = device.fallbackHost,
            lockOnLeaveEnabled = device.lockOnLeaveEnabled
        )
        prefs.edit().putString(rowKey(device.deviceId), Json.encodeToString(TrustedDeviceRow.serializer(), row)).apply()
    }

    /** Updates just the fallback address for an already-trusted device (see
     *  [TrustedDevice.fallbackHost]). No-ops if [deviceId] isn't trusted. */
    @Synchronized
    fun setFallbackHost(deviceId: String, fallbackHost: String?) {
        val existing = getDevice(deviceId) ?: return
        addDevice(existing.copy(fallbackHost = fallbackHost?.trim()?.takeIf { it.isNotEmpty() }))
    }

    /** Updates just the Lock-on-Leave flag for an already-trusted Mac (see
     *  [TrustedDevice.lockOnLeaveEnabled]). No-ops if [deviceId] isn't trusted. */
    @Synchronized
    fun setLockOnLeaveEnabled(deviceId: String, enabled: Boolean) {
        val existing = getDevice(deviceId) ?: return
        addDevice(existing.copy(lockOnLeaveEnabled = enabled))
    }

    @Synchronized
    fun isTrusted(deviceId: String): Boolean = prefs.contains(rowKey(deviceId))

    @Synchronized
    fun getDevice(deviceId: String): TrustedDevice? =
        prefs.getString(rowKey(deviceId), null)?.let { parse(it) }

    @Synchronized
    fun allDevices(): List<TrustedDevice> =
        prefs.all.entries
            .filter { it.key.startsWith(ROW_PREFIX) }
            .mapNotNull { (it.value as? String)?.let { json -> parse(json) } }
            .sortedBy { it.addedAt }

    @Synchronized
    fun revoke(deviceId: String) {
        prefs.edit().remove(rowKey(deviceId)).apply()
    }

    private fun parse(json: String): TrustedDevice {
        val row = Json.decodeFromString(TrustedDeviceRow.serializer(), json)
        return TrustedDevice(
            deviceId = row.deviceId,
            publicKey = Base64.getDecoder().decode(row.publicKeyBase64),
            deviceName = row.deviceName,
            deviceType = DeviceType.fromWire(row.deviceType),
            addedAt = row.addedAt,
            fallbackHost = row.fallbackHost,
            lockOnLeaveEnabled = row.lockOnLeaveEnabled
        )
    }

    private fun rowKey(deviceId: String) = "$ROW_PREFIX$deviceId"

    companion object {
        private const val PREFS_FILE = "connect_trusted_devices"
        private const val ROW_PREFIX = "device_"

        @Volatile
        private var instance: TrustedDevicesStore? = null

        fun getInstance(context: Context): TrustedDevicesStore =
            instance ?: synchronized(this) {
                instance ?: build(context.applicationContext).also { instance = it }
            }

        private fun build(context: Context): TrustedDevicesStore {
            val masterKey = MasterKey.Builder(context)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            val prefs = EncryptedSharedPreferences.create(
                context,
                PREFS_FILE,
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )
            return TrustedDevicesStore(prefs)
        }
    }
}
