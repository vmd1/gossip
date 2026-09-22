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
    val addedAt: Long
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is TrustedDevice) return false
        return deviceId == other.deviceId &&
            publicKey.contentEquals(other.publicKey) &&
            deviceName == other.deviceName &&
            deviceType == other.deviceType &&
            addedAt == other.addedAt
    }

    override fun hashCode(): Int = deviceId.hashCode()
}

@Serializable
private data class TrustedDeviceRow(
    val deviceId: String,
    val publicKeyBase64: String,
    val deviceName: String,
    val deviceType: String,
    val addedAt: Long
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
            addedAt = device.addedAt
        )
        prefs.edit().putString(rowKey(device.deviceId), Json.encodeToString(TrustedDeviceRow.serializer(), row)).apply()
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
            addedAt = row.addedAt
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
