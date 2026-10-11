package dev.vmd1.gossip.crypto

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import dev.vmd1.gossip.protocol.DeviceType
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import java.util.Base64
import java.util.concurrent.CopyOnWriteArrayList

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
    val signingPublicKey: ByteArray? = null,
    /** The key this device uses to tag its BLE advertisements, shared over the encrypted mesh
     *  (`ble.beacon_key`); `null` until received. See `BeaconTag`. */
    val beaconKey: ByteArray? = null
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
            } &&
            (beaconKey?.contentEquals(other.beaconKey ?: return false) ?: (other.beaconKey == null))
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
    val signingPublicKeyBase64: String? = null,
    val beaconKeyBase64: String? = null
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

    private val provisional = HashSet<String>()

    /** Called (on whatever thread made the change, after it is applied) whenever the table changes. Listeners must not
     *  block or take locks that a thread holding this store's monitor could be waiting on: hand the work to another thread. */
    private val changeListeners = CopyOnWriteArrayList<() -> Unit>()

    fun addChangeListener(listener: () -> Unit) { changeListeners.add(listener) }

    private fun notifyChanged() {
        for (listener in changeListeners) runCatching { listener() }
    }

    /** A row added during pairing but not yet confirmed by the other side; kept out of roster gossip. In memory only. */
    @Synchronized fun markProvisional(deviceId: String) { provisional.add(deviceId); notifyChanged() }
    @Synchronized fun clearProvisional(deviceId: String) { provisional.remove(deviceId); notifyChanged() }
    @Synchronized fun isProvisional(deviceId: String): Boolean = deviceId in provisional
    @Synchronized fun provisionalIds(): List<String> = provisional.toList()

    @Synchronized
    fun addDevice(device: TrustedDevice) {
        writeDevice(device)
        notifyChanged()
    }

    /** Writes the row (and clears any tombstone) without notifying listeners. */
    private fun writeDevice(device: TrustedDevice) {
        val row = TrustedDeviceRow(
            deviceId = device.deviceId,
            publicKeyBase64 = Base64.getEncoder().encodeToString(device.publicKey),
            deviceName = device.deviceName,
            deviceType = device.deviceType.wireValue,
            addedAt = device.addedAt,
            fallbackHost = device.fallbackHost,
            lockOnLeaveEnabled = device.lockOnLeaveEnabled,
            signingPublicKeyBase64 = device.signingPublicKey?.let { Base64.getEncoder().encodeToString(it) },
            beaconKeyBase64 = device.beaconKey?.let { Base64.getEncoder().encodeToString(it) }
        )
        prefs.edit()
            .putString(rowKey(device.deviceId), Json.encodeToString(TrustedDeviceRow.serializer(), row))
            .remove(revokedKey(device.deviceId))
            .apply()
    }

    /** Updates just the fallback address for an already-trusted device (see
     *  [TrustedDevice.fallbackHost]). No-ops if [deviceId] isn't trusted. */
    @Synchronized
    fun setFallbackHost(deviceId: String, fallbackHost: String?): Boolean {
        val existing = getDevice(deviceId) ?: return false
        val trimmed = fallbackHost?.trim()?.takeIf { it.isNotEmpty() }
        if (trimmed != null && !HostValidator.isValid(trimmed)) return false
        addDevice(existing.copy(fallbackHost = trimmed))
        return true
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

    /** Records the beacon key a trusted device sent over the mesh. Returns true if it changed anything;
     *  idempotent, and a no-op for an unknown device. */
    @Synchronized
    fun setBeaconKey(deviceId: String, beaconKey: ByteArray): Boolean {
        val existing = getDevice(deviceId) ?: return false
        if (existing.beaconKey?.contentEquals(beaconKey) == true) return false
        addDevice(existing.copy(beaconKey = beaconKey))
        return true
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

    /** Drops a row without a tombstone — for a pairing that never completed, not a revocation. */
    @Synchronized
    fun remove(deviceId: String) {
        prefs.edit().remove(rowKey(deviceId)).apply()
        notifyChanged()
    }

    /** Removes the device and records a sticky tombstone so gossip can't quietly bring it
     *  back. [revokedAt] is when the revocation happened (Unix ms); the later of two wins.
     *  Pairing the device directly again clears the tombstone (see [addDevice]). */
    @Synchronized
    fun revoke(deviceId: String, revokedAt: Long = System.currentTimeMillis()) {
        val latest = maxOf(revokedAt(deviceId) ?: 0L, revokedAt)
        prefs.edit().remove(rowKey(deviceId)).putLong(revokedKey(deviceId), latest).apply()
        notifyChanged()
    }

    @Synchronized
    fun revokedAt(deviceId: String): Long? =
        if (prefs.contains(revokedKey(deviceId))) prefs.getLong(revokedKey(deviceId), 0L) else null

    // ---- Rust engine snapshot -------------------------------------------------------------------------------------

    /**
     * The trust table in the Rust engine's snapshot format (`desktop/core` `TrustSnapshot`). The engine is created from
     * this, and handed a fresh copy whenever the app edits the table itself (see `CoreBridge.syncTrustFromStore`).
     * App-only fields (fallback host, lock-on-leave) never go to the engine.
     */
    @Synchronized
    fun exportCoreSnapshot(): String {
        val enc = Base64.getEncoder()
        val devices = buildJsonArray {
            for (d in allDevices()) {
                add(buildJsonObject {
                    put("device_id", JsonPrimitive(d.deviceId))
                    put("public_key", JsonPrimitive(enc.encodeToString(d.publicKey)))
                    put("device_name", JsonPrimitive(d.deviceName))
                    put("device_type", JsonPrimitive(d.deviceType.wireValue))
                    put("added_at", JsonPrimitive(d.addedAt))
                    put("signing_public_key", d.signingPublicKey?.let { JsonPrimitive(enc.encodeToString(it)) } ?: JsonNull)
                    put("beacon_key", d.beaconKey?.let { JsonPrimitive(enc.encodeToString(it)) } ?: JsonNull)
                })
            }
        }
        val revoked = buildJsonObject {
            for ((key, value) in prefs.all) {
                if (key.startsWith(REVOKED_PREFIX) && value is Long) put(key.removePrefix(REVOKED_PREFIX), JsonPrimitive(value))
            }
        }
        return buildJsonObject {
            put("devices", devices)
            put("revoked", revoked)
        }.toString()
    }

    /**
     * Applies a snapshot the engine reported after its trust changed (a pairing was confirmed, a roster introduced a
     * device, a revocation arrived, a signing key was learned from a handshake). Existing rows keep their app-only
     * fields and a new row is added; only a device the engine has *revoked* is removed. "Missing from the snapshot" is
     * deliberately not a removal: the app may have added a row after the engine produced it. Returns whether anything
     * changed.
     */
    @Synchronized
    fun importCoreSnapshot(json: String): Boolean {
        val root = runCatching { Json.parseToJsonElement(json).jsonObject }.getOrNull() ?: return false
        val rows = (root["devices"] as? JsonArray) ?: return false
        val tombstones = (root["revoked"] as? JsonObject)?.mapNotNull { (id, v) ->
            (v as? JsonPrimitive)?.longOrNull?.let { id to it }
        }?.toMap() ?: emptyMap()
        val dec = Base64.getDecoder()
        var changed = false
        val seen = HashSet<String>()
        // Applied after the loop so one batched write is not notified as many separate changes.
        for (element in rows) {
            val row = element as? JsonObject ?: continue
            val id = row["device_id"]?.jsonPrimitive?.contentOrNull ?: continue
            val key = row["public_key"]?.jsonPrimitive?.contentOrNull?.let { runCatching { dec.decode(it) }.getOrNull() } ?: continue
            val name = row["device_name"]?.jsonPrimitive?.contentOrNull ?: continue
            val typeRaw = row["device_type"]?.jsonPrimitive?.contentOrNull ?: continue
            val signing = row["signing_public_key"]?.jsonPrimitive?.contentOrNull?.let { runCatching { dec.decode(it) }.getOrNull() }
            seen.add(id)
            val existing = getDevice(id)
            if (existing != null) {
                // Only the signing key (learned from an authenticated handshake) can have changed on an existing row.
                if (signing != null && existing.signingPublicKey?.contentEquals(signing) != true) {
                    writeDevice(existing.copy(signingPublicKey = signing))
                    changed = true
                }
            } else if (DeviceType.entries.any { it.wireValue == typeRaw }) {
                // A device type this app has no case for (a future platform) can be trusted by the engine and relayed
                // through, but has no row to show yet.
                val addedAt = row["added_at"]?.jsonPrimitive?.longOrNull ?: System.currentTimeMillis()
                writeDevice(TrustedDevice(id, key, name, DeviceType.fromWire(typeRaw), addedAt, signingPublicKey = signing))
                changed = true
            }
        }
        for ((id, at) in tombstones) {
            if (id !in seen && isTrusted(id)) {
                prefs.edit().remove(rowKey(id)).apply()
                changed = true
            }
            if ((revokedAt(id) ?: Long.MIN_VALUE) < at) {
                prefs.edit().putLong(revokedKey(id), at).apply()
                changed = true
            }
        }
        if (changed) notifyChanged()
        return changed
    }

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
            signingPublicKey = row.signingPublicKeyBase64?.let { Base64.getDecoder().decode(it) },
            beaconKey = row.beaconKeyBase64?.let { Base64.getDecoder().decode(it) }
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
