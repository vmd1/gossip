package dev.vmd1.gossip.features.proximity

import dev.vmd1.gossip.crypto.IdentityKeyStore
import dev.vmd1.gossip.crypto.TrustedDevicesStore
import dev.vmd1.gossip.transport.TransportManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import uniffi.gossip_ffi.beaconKeyParse
import uniffi.gossip_ffi.beaconKeyPayload
import uniffi.gossip_ffi.beaconKeySlot
import uniffi.gossip_ffi.bleAcceptableTags
import uniffi.gossip_ffi.bleBeaconTag
import uniffi.gossip_ffi.bleBeaconWindow

/**
 * Keyed, rotating BLE proximity advertisements. A phone no longer advertises a constant hash of its public
 * key (which anyone who knows that key could replay, and any passer-by could track); it advertises
 * `tag(beaconKey, window)` — 8 bytes of HMAC-SHA256 over a 1-minute time window — and only devices it has
 * shared its `beaconKey` with (over the Noise-encrypted mesh, see [BeaconKeyManager]) can recognise it. Mac
 * has the same functions (`BeaconKey.swift`); both are checked against `schema/ble-beacon-vectors.json`.
 * See `docs/ble-proximity-protocol.md`.
 */
object BeaconTag {
    // The tag function and the window are the core's (`desktop/core/src/crypto/beacon.rs`), shared with every platform.
    const val WINDOW_SECONDS = 60L

    fun window(nowMs: Long = System.currentTimeMillis()): Long = bleBeaconWindow((maxOf(0L, nowMs) / 1000).toULong()).toLong()

    fun tag(key: ByteArray, window: Long): ByteArray = bleBeaconTag(key, window.toULong())

    /** Tags a device holding [key] may be advertising right now, allowing one window of clock skew either way. */
    fun acceptableTags(key: ByteArray, nowMs: Long = System.currentTimeMillis()): List<ByteArray> =
        bleAcceptableTags(key, (maxOf(0L, nowMs) / 1000).toULong())

    /** Milliseconds until the current window ends, so an advertiser can re-arm with the next tag on time. */
    fun millisUntilNextWindow(nowMs: Long = System.currentTimeMillis()): Long =
        WINDOW_SECONDS * 1000 - (nowMs % (WINDOW_SECONDS * 1000))
}

/**
 * Shares this device's BLE beacon key with its directly connected trusted peers (so they can recognise its advertisements)
 * and stores the keys peers share. The key is the **direct-only** `direct.ble.beacon_key` state slot (see
 * `docs/plans/state-sync.md`): the core sends it only to devices connected straight to this one, never through the mesh,
 * and keeps it correct across reconnects, so nothing here resends it.
 */
class BeaconKeyManager(
    private val transportManager: TransportManager,
    private val trustedDevicesStore: TrustedDevicesStore,
    private val identityKeyStore: IdentityKeyStore,
    scope: CoroutineScope,
    /** Called after a peer's key is stored, so the monitor can rebuild its tag table. */
    private val onKeysChanged: () -> Unit = {}
) {
    init {
        scope.launch {
            transportManager.stateChanges.collect { change ->
                if (change.slot == beaconKeySlot()) handle(change.deviceId, change.value?.toString())
            }
        }
        transportManager.setState(beaconKeySlot(), Json.parseToJsonElement(beaconKeyPayload(identityKeyStore.beaconKey)))
    }

    private fun handle(deviceId: String, valueJson: String?) {
        val key = valueJson?.let { beaconKeyParse(it) } ?: return
        if (!trustedDevicesStore.isTrusted(deviceId)) return
        if (trustedDevicesStore.setBeaconKey(deviceId, key)) onKeysChanged()
    }
}
