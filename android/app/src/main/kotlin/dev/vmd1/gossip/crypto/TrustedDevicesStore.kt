package dev.vmd1.gossip.crypto

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import dev.vmd1.gossip.protocol.DeviceType
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
    val lockOnLeaveEnabled: Boolean = false,
    /** This device's Ed25519 *signing* public key (distinct from [publicKey], the X25519
     *  key-agreement key used for Noise_IK) — used to verify signed GATT requests (e.g.
     *  Instant Hotspot's `hotspot.toggle_request`). `null` for a row paired before this
     *  field existed; see [TrustedDevicesStore.backfillSigningPublicKey]. */
    val signingPublicKey: ByteArray? = null
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
            lockOnLeaveEnabled == other.lockOnLeaveEnabled &&
            when {
                signingPublicKey == null && other.signingPublicKey == null -> true
                signingPublicKey == null || other.signingPublicKey == null -> false
                else -> signingPublicKey.contentEquals(other.signingPublicKey)
            }
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
    val lockOnLeaveEnabled: Boolean = false,
    val signingPublicKeyBase64: String? = null
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
            lockOnLeaveEnabled = device.lockOnLeaveEnabled,
            signingPublicKeyBase64 = device.signingPublicKey?.let { Base64.getEncoder().encodeToString(it) }
        )
        prefs.edit()
            .putString(rowKey(device.deviceId), Json.encodeToString(TrustedDeviceRow.serializer(), row))
            .remove(revokedKey(device.deviceId))
            .apply()
    }

    /** Updates just the fallback address for an already-trusted device (see
     *  [TrustedDevice.fallbackHost]). No-ops if [deviceId] isn't trusted. */
    @Synchronized
    fun setFallbackHost(deviceId: String, fallbackHost: String?) {
        val existing = getDevice(deviceId) ?: return
        addDevice(existing.copy(fallbackHost = fallbackHost?.trim()?.takeIf { it.isNotEmpty() }))
    }

    /** Records the signing key a device presented inside an authenticated Noise handshake
     *  (bound to the static key this device was paired with). Replaces a missing value or
     *  one learned second-hand via gossip. Idempotent; no-ops if [deviceId] isn't trusted. */
    @Synchronized
    fun setSigningPublicKey(deviceId: String, signingPublicKey: ByteArray) {
        val existing = getDevice(deviceId) ?: return
        if (existing.signingPublicKey?.contentEquals(signingPublicKey) == true) return
        addDevice(existing.copy(signingPublicKey = signingPublicKey))
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

    /** Removes the device and records a sticky tombstone so gossip can't quietly bring it
     *  back. [revokedAt] is when the revocation happened (Unix ms); the later of two wins.
     *  Pairing the device directly again clears the tombstone (see [addDevice]). */
    @Synchronized
    fun revoke(deviceId: String, revokedAt: Long = System.currentTimeMillis()) {
        val latest = maxOf(revokedAt(deviceId) ?: 0L, revokedAt)
        prefs.edit().remove(rowKey(deviceId)).putLong(revokedKey(deviceId), latest).apply()
    }

    @Synchronized
    fun revokedAt(deviceId: String): Long? =
        if (prefs.contains(revokedKey(deviceId))) prefs.getLong(revokedKey(deviceId), 0L) else null

    private fun parse(json: String): TrustedDevice {
        val row = rowJson.decodeFromString(TrustedDeviceRow.serializer(), json)
        return TrustedDevice(
            deviceId = row.deviceId,
            publicKey = Base64.getDecoder().decode(row.publicKeyBase64),
            deviceName = row.deviceName,
            deviceType = DeviceType.fromWire(row.deviceType),
            addedAt = row.addedAt,
            fallbackHost = row.fallbackHost,
            lockOnLeaveEnabled = row.lockOnLeaveEnabled,
            signingPublicKey = row.signingPublicKeyBase64?.let { Base64.getDecoder().decode(it) }
        )
    }

    /** Tolerates keys from rows written by older builds (e.g. the removed `autoHotspotRequestEligible`),
     *  so dropping a field never makes an existing paired device fail to load. */
    private val rowJson = Json { ignoreUnknownKeys = true }

    private fun rowKey(deviceId: String) = "$ROW_PREFIX$deviceId"
    private fun revokedKey(deviceId: String) = "$REVOKED_PREFIX$deviceId"

    companion object {
        private const val PREFS_FILE = "connect_trusted_devices"
        private const val ROW_PREFIX = "device_"
        private const val REVOKED_PREFIX = "revoked_"

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
