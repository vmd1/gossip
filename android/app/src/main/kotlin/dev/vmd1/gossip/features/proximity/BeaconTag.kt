package dev.vmd1.gossip.features.proximity

import dev.vmd1.gossip.crypto.IdentityKeyStore
import dev.vmd1.gossip.crypto.TrustedDevicesStore
import dev.vmd1.gossip.protocol.Envelope
import dev.vmd1.gossip.protocol.MessageType
import dev.vmd1.gossip.transport.EnvelopeHandler
import dev.vmd1.gossip.transport.MessageRouter
import dev.vmd1.gossip.transport.TransportManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import java.util.Base64
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Keyed, rotating BLE proximity advertisements. A phone no longer advertises a constant hash of its public
 * key (which anyone who knows that key could replay, and any passer-by could track); it advertises
 * `tag(beaconKey, window)` — 8 bytes of HMAC-SHA256 over a 2-minute time window — and only devices it has
 * shared its `beaconKey` with (over the Noise-encrypted mesh, see [BeaconKeyManager]) can recognise it. Mac
 * has the same functions (`BeaconKey.swift`); both are checked against `schema/ble-beacon-vectors.json`.
 * See `docs/ble-proximity-protocol.md`.
 */
object BeaconTag {
    const val WINDOW_SECONDS = 120L
    private val LABEL = "gossip-ble-v1".toByteArray(Charsets.UTF_8)

    fun window(nowMs: Long = System.currentTimeMillis()): Long = maxOf(0L, nowMs / 1000) / WINDOW_SECONDS

    fun tag(key: ByteArray, window: Long): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        mac.update(LABEL)
        mac.update(java.nio.ByteBuffer.allocate(8).putLong(window).array())
        return mac.doFinal().copyOfRange(0, 8)
    }

    /** Tags a device holding [key] may be advertising right now, allowing one window of clock skew either way. */
    fun acceptableTags(key: ByteArray, nowMs: Long = System.currentTimeMillis()): List<ByteArray> {
        val w = window(nowMs)
        return listOf(w - 1, w, w + 1).map { tag(key, it) }
    }

    /** Milliseconds until the current window ends, so an advertiser can re-arm with the next tag on time. */
    fun millisUntilNextWindow(nowMs: Long = System.currentTimeMillis()): Long =
        WINDOW_SECONDS * 1000 - (nowMs % (WINDOW_SECONDS * 1000))
}

/**
 * Implements `ble.beacon_key`: tells every directly-connected trusted peer this device's beacon key (so they can
 * recognise its advertisements) and stores the keys peers send. State configured on the recipient, so it
 * self-heals like `trust.roster_update`: resent on every fresh connect and on a 5-minute resync; handling it
 * twice is a no-op.
 */
class BeaconKeyManager(
    private val transportManager: TransportManager,
    private val trustedDevicesStore: TrustedDevicesStore,
    private val identityKeyStore: IdentityKeyStore,
    messageRouter: MessageRouter,
    private val scope: CoroutineScope,
    /** Called after a peer's key is stored, so the monitor can rebuild its tag table. */
    private val onKeysChanged: () -> Unit = {}
) {
    private var knownConnectedIds: Set<String> = emptySet()

    init {
        messageRouter.register(MessageType.BLE_BEACON_KEY, EnvelopeHandler { handle(it) })
        transportManager.connectedDeviceIds
            .onEach { current ->
                val newlyConnected = current - knownConnectedIds
                knownConnectedIds = current
                for (id in newlyConnected) send(id)
            }
            .launchIn(scope)
    }

    fun periodicResync() {
        for (device in trustedDevicesStore.allDevices()) send(device.deviceId)
    }

    private fun send(to: String) {
        scope.launch {
            runCatching {
                transportManager.send(
                    Envelope(
                        type = MessageType.BLE_BEACON_KEY,
                        senderId = identityKeyStore.deviceId,
                        recipientId = to,
                        ttl = 0, // key material: direct connections only
                        payload = buildJsonObject {
                            put("key", JsonPrimitive(Base64.getEncoder().encodeToString(identityKeyStore.beaconKey)))
                        }
                    )
                )
            }
        }
    }

    private fun handle(envelope: Envelope) {
        val base64 = envelope.payload["key"]?.jsonPrimitive?.contentOrNull ?: return
        val key = runCatching { Base64.getDecoder().decode(base64) }.getOrNull() ?: return
        if (key.size != 32 || !trustedDevicesStore.isTrusted(envelope.senderId)) return
        if (trustedDevicesStore.setBeaconKey(envelope.senderId, key)) onKeysChanged()
    }
}
