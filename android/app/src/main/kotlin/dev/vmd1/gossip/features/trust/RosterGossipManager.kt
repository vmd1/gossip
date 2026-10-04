package dev.vmd1.gossip.features.trust

import android.util.Base64
import dev.vmd1.gossip.util.Log
import dev.vmd1.gossip.crypto.IdentityKeyStore
import dev.vmd1.gossip.crypto.TrustedDevice
import dev.vmd1.gossip.crypto.TrustedDevicesStore
import dev.vmd1.gossip.protocol.DeviceType
import dev.vmd1.gossip.protocol.Envelope
import dev.vmd1.gossip.protocol.MessageType
import dev.vmd1.gossip.transport.EnvelopeHandler
import dev.vmd1.gossip.transport.MessageRouter
import dev.vmd1.gossip.transport.TransportManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

private const val TAG = "RosterGossipManager"

/**
 * Implements the `trust.roster_update` / `trust.revoke` message types: gossips this
 * device's local `TrustedDevices` roster to the rest of the mesh so pairing with any one
 * existing member propagates to every other member automatically — nobody needs to
 * individually re-pair with every other device by hand. See
 * `docs/adr/0002-device-group-addressing.md` and the mesh-support ADR.
 *
 * Trust is transitive and automatic: a gossiped entry for a device this device has never
 * paired with directly is merged straight into [TrustedDevicesStore], with no user
 * confirmation prompt — justified because the gossip arrives over an already-Noise-
 * authenticated direct connection from an already-trusted device. Once trusted this way,
 * a subsequent direct connection to that device (or a fallback-host dial) will connect to
 * it normally; until then, messages still reach it via multi-hop relay through whichever
 * device it *is* gossiped through (see `docs/wire-protocol.md`'s "Multi-hop relay"
 * section).
 */
class RosterGossipManager(
    private val transportManager: TransportManager,
    private val trustedDevicesStore: TrustedDevicesStore,
    private val identityKeyStore: IdentityKeyStore,
    messageRouter: MessageRouter,
    private val scope: CoroutineScope,
    private val deviceName: String,
    private val deviceType: DeviceType = DeviceType.ANDROID_PHONE
) {
    /** The connected-device set as of the last time we reacted to it, so we only send a
     *  fresh peer our roster once — on the transition into `connectedDeviceIds`, not on
     *  every subsequent emission of the same set. */
    private var knownConnectedIds: Set<String> = emptySet()

    init {
        messageRouter.register(MessageType.TRUST_ROSTER_UPDATE, EnvelopeHandler { handleRosterUpdate(it) })
        messageRouter.register(MessageType.TRUST_REVOKE, EnvelopeHandler { handleRevoke(it) })

        // Every fresh connection (a reconnect, or a freshly-confirmed pairing) gets this
        // device's current roster, targeted just at them — the newly-connected peer is
        // exactly who's missing the most information.
        transportManager.connectedDeviceIds
            .onEach { current ->
                val newlyConnected = current - knownConnectedIds
                knownConnectedIds = current
                for (deviceId in newlyConnected) {
                    sendRoster(to = deviceId)
                }
            }
            .launchIn(scope)

        // A brand-new pairing completed via the *responder* role (this device showed a
        // QR and an untrusted peer just confirmed) — broadcast to the rest of the mesh,
        // same as `announceNewDevice()` (called explicitly by `PairingViewModel` for the
        // *initiator*-role/QR-scan flow instead, since that flow doesn't go through
        // `TransportManager.onNewDevicePaired`).
        transportManager.onNewDevicePaired = { announceNewDevice() }
    }

    /** Re-broadcasts the full local roster to all connected peers — a self-healing
     *  backstop for dropped messages, mirroring the existing DND resync-loop convention.
     *  Call periodically (e.g. every 5 minutes) while the service is running. */
    fun periodicResync() {
        scope.launch { broadcastRoster() }
    }

    /** Call right after adding a brand-new device to [TrustedDevicesStore] via pairing
     *  (not a reconnect) — broadcasts the updated roster to the rest of the mesh so it
     *  learns about the new device without waiting for the periodic resync.
     *  Flood-forwarding then carries it transitively through the whole mesh for free. */
    fun announceNewDevice() {
        scope.launch { broadcastRoster() }
    }

    /** UI should call this instead of [TrustedDevicesStore.revoke] directly: revokes
     *  locally and broadcasts `trust.revoke` so the rest of the mesh drops trust (and any
     *  live connection) for this device too, rather than caching it forever on any device
     *  that doesn't happen to talk to the revoker again. */
    fun revoke(deviceId: String) {
        trustedDevicesStore.revoke(deviceId)
        transportManager.disconnect(deviceId)
        scope.launch {
            runCatching {
                transportManager.send(
                    Envelope(
                        type = MessageType.TRUST_REVOKE,
                        senderId = identityKeyStore.deviceId,
                        broadcast = true,
                        payload = revokePayload(deviceId, trustedDevicesStore.revokedAt(deviceId))
                    )
                )
            }.onFailure { Log.w(TAG, "Failed to broadcast trust.revoke: ${it.message}") }
        }
    }

    private fun revokePayload(deviceId: String, revokedAt: Long?): JsonObject = buildJsonObject {
        put("deviceId", JsonPrimitive(deviceId))
        if (revokedAt != null) put("revokedAt", JsonPrimitive(revokedAt))
    }

    // MARK: Sending

    private suspend fun sendRoster(to: String) {
        runCatching {
            transportManager.send(
                Envelope(
                    type = MessageType.TRUST_ROSTER_UPDATE,
                    senderId = identityKeyStore.deviceId,
                    recipientId = to,
                    payload = rosterPayload()
                )
            )
        }.onFailure { Log.w(TAG, "Failed to send roster to $to: ${it.message}") }
    }

    private suspend fun broadcastRoster() {
        runCatching {
            transportManager.send(
                Envelope(
                    type = MessageType.TRUST_ROSTER_UPDATE,
                    senderId = identityKeyStore.deviceId,
                    broadcast = true,
                    payload = rosterPayload()
                )
            )
        }.onFailure { Log.w(TAG, "Failed to broadcast roster: ${it.message}") }
    }

    /** Every device this device currently trusts, plus itself — a recipient meeting the
     *  mesh for the first time via a relayed broadcast (rather than a direct targeted
     *  send) needs to learn about the sender too, not just the sender's other peers. */
    private fun rosterPayload(): JsonObject = buildJsonObject {
        put(
            "devices",
            buildJsonArray {
                for (device in trustedDevicesStore.allDevices().filterNot { trustedDevicesStore.isProvisional(it.deviceId) }) {
                    add(
                        buildJsonObject {
                            put("deviceId", JsonPrimitive(device.deviceId))
                            put("publicKey", JsonPrimitive(Base64.encodeToString(device.publicKey, Base64.NO_WRAP)))
                            put("deviceName", JsonPrimitive(device.deviceName))
                            put("deviceType", JsonPrimitive(device.deviceType.wireValue))
                            device.signingPublicKey?.let {
                                put("signingPublicKey", JsonPrimitive(Base64.encodeToString(it, Base64.NO_WRAP)))
                            }
                            put("addedAt", JsonPrimitive(device.addedAt))
                        }
                    )
                }
                add(
                    buildJsonObject {
                        put("deviceId", JsonPrimitive(identityKeyStore.deviceId))
                        put("publicKey", JsonPrimitive(Base64.encodeToString(identityKeyStore.x25519KeyPair.publicKey, Base64.NO_WRAP)))
                        put("deviceName", JsonPrimitive(deviceName))
                        put("deviceType", JsonPrimitive(deviceType.wireValue))
                        put("signingPublicKey", JsonPrimitive(Base64.encodeToString(identityKeyStore.ed25519PublicKey, Base64.NO_WRAP)))
                    }
                )
            }
        )
    }

    // MARK: Receiving

    private fun handleRosterUpdate(envelope: Envelope) {
        val entries = (envelope.payload["devices"] as? JsonArray) ?: return
        for (entry in entries.take(MAX_ENTRIES_PER_MESSAGE)) {
            val obj = entry as? JsonObject ?: continue
            val deviceId = obj["deviceId"]?.jsonPrimitive?.contentOrNull ?: continue
            if (!isUuid(deviceId) || deviceId == identityKeyStore.deviceId) continue
            // Never clobber an already-trusted device's own row (e.g. one paired directly, or
            // already gossiped) with a remote-reported copy — this would otherwise re-stamp
            // `addedAt` on every periodic resync. The signing key is likewise never taken from
            // gossip for an existing row; it is learned from the device's own authenticated
            // handshake.
            if (trustedDevicesStore.isTrusted(deviceId)) continue
            // A revoked device stays revoked: gossip can never bring it back (a malicious introducer could claim any
            // `addedAt`), only pairing it directly again clears the tombstone. A peer still introducing it missed
            // the revoke, so tell it again.
            val revokedAt = trustedDevicesStore.revokedAt(deviceId)
            if (revokedAt != null) {
                scope.launch {
                    runCatching {
                        transportManager.send(
                            Envelope(
                                type = MessageType.TRUST_REVOKE,
                                senderId = identityKeyStore.deviceId,
                                recipientId = envelope.senderId,
                                payload = revokePayload(deviceId, revokedAt)
                            )
                        )
                    }
                }
                continue
            }
            val publicKey = decodeKey(obj["publicKey"]?.jsonPrimitive?.contentOrNull) ?: continue
            val deviceNameEntry = obj["deviceName"]?.jsonPrimitive?.contentOrNull ?: continue
            val deviceTypeRaw = obj["deviceType"]?.jsonPrimitive?.contentOrNull ?: continue
            val signingPublicKey = decodeKey(obj["signingPublicKey"]?.jsonPrimitive?.contentOrNull)
            if (trustedDevicesStore.allDevices().size >= MAX_TRUSTED_DEVICES) break
            trustedDevicesStore.addDevice(
                TrustedDevice(
                    deviceId = deviceId,
                    publicKey = publicKey,
                    deviceName = deviceNameEntry.take(80),
                    deviceType = DeviceType.fromWire(deviceTypeRaw),
                    addedAt = System.currentTimeMillis(),
                    signingPublicKey = signingPublicKey
                )
            )
        }
    }

    private fun handleRevoke(envelope: Envelope) {
        val deviceId = envelope.payload["deviceId"]?.jsonPrimitive?.contentOrNull ?: return
        if (!isUuid(deviceId) || deviceId == identityKeyStore.deviceId) return
        // A far-future `revokedAt` would make the tombstone un-clearable by any honest means; clamp it to now.
        val revokedAt = minOf(envelope.payload["revokedAt"]?.jsonPrimitive?.longOrNull ?: envelope.ts, System.currentTimeMillis())
        trustedDevicesStore.revoke(deviceId, revokedAt)
        transportManager.disconnect(deviceId)
    }

    companion object {
        /** Roster limits: entries per message, and how many devices gossip may ever make this device trust. */
        const val MAX_ENTRIES_PER_MESSAGE = 64
        const val MAX_TRUSTED_DEVICES = 64

        fun isUuid(value: String): Boolean = runCatching { java.util.UUID.fromString(value) }.isSuccess && value.length == 36

        /** A base64 32-byte key (X25519 / Ed25519), or null if it isn't one. */
        fun decodeKey(base64: String?): ByteArray? =
            base64?.let { runCatching { java.util.Base64.getDecoder().decode(it) }.getOrNull() }?.takeIf { it.size == 32 }
    }
}
