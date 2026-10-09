package dev.vmd1.gossip.transport

import dev.vmd1.gossip.crypto.IdentityKeyStore
import dev.vmd1.gossip.crypto.TrustedDevicesStore
import dev.vmd1.gossip.protocol.DeviceType
import dev.vmd1.gossip.protocol.Envelope
import kotlinx.serialization.json.JsonObject
import uniffi.gossip_ffi.GossipCore
import uniffi.gossip_ffi.GossipException
import uniffi.gossip_ffi.Action as CoreAction
import uniffi.gossip_ffi.Envelope as CoreEnvelope
import uniffi.gossip_ffi.PeerInfo as CorePeerInfo

/**
 * The only file that talks to the Rust engine (`desktop/core`, through the UniFFI bindings in `uniffi.gossip_ffi`).
 *
 * The engine owns the protocol: Noise_IK, framing, envelope signing and verification, the mesh forwarding rules,
 * trust gating of new devices, heartbeats and reconciliation timing. It is sans-IO: this file feeds it bytes and
 * events and turns what it returns into [BridgeAction]s that [TransportManager] carries out on real sockets.
 * Everything FFI-shaped (generated types, JSON payloads, the trust snapshot format) stays here, so the rest of the
 * app keeps using its own [Envelope], [HandshakePeerInfo] and [TrustedDevicesStore]. Mirrors the Mac's `CoreBridge`.
 *
 * Not thread-safe by itself on purpose: [TransportManager] calls it only while holding its engine lock, which is also
 * what keeps the bytes written to a socket in the order the engine produced them (Noise nonces are implicit counters).
 */
class CoreBridge(
    deviceId: String,
    /** 32-byte X25519 secret ([IdentityKeyStore.x25519KeyPair]'s private key). */
    noiseSecret: ByteArray,
    /** 32-byte Ed25519 seed ([IdentityKeyStore.ed25519PrivateKey]). */
    signingSeed: ByteArray,
    deviceName: String,
    deviceType: DeviceType,
    private val trustedDevices: TrustedDevicesStore,
    disabledFeatures: List<String>
) {
    /** What [TransportManager] must do (or tell the rest of the app) as a result of one engine call. */
    sealed class BridgeAction {
        /** Write these bytes (already length-framed) to the connection. */
        class Send(val conn: ULong, val bytes: ByteArray) : BridgeAction()

        /** Close the connection. The engine has already forgotten it. */
        class Close(val conn: ULong) : BridgeAction()
        class PeerConnected(val conn: ULong, val peer: HandshakePeerInfo, val newlyPaired: Boolean) : BridgeAction()
        class PeerDisconnected(val deviceId: String) : BridgeAction()

        /** An unknown device needs the user's confirmation; answer with [confirmPairing]. */
        class PairingPrompt(val conn: ULong, val peer: HandshakePeerInfo, val publicKey: ByteArray, val code: String) : BridgeAction()
        class PairingPromptCancelled(val conn: ULong) : BridgeAction()
        class Deliver(val envelope: Envelope, val raw: ByteArray?) : BridgeAction()

        /** A validated message from this device arrived (even relayed): it is reachable. */
        class Heard(val deviceId: String) : BridgeAction()

        /** The trust roster changed; the JSON is the engine's snapshot. */
        class TrustChanged(val snapshotJson: String) : BridgeAction()
        class DeviceRevoked(val deviceId: String) : BridgeAction()

        /** A reconciliation resend is due: [peer] for the on-connect send to one peer, `null` for the periodic broadcast. */
        class ReconcileDue(val task: String, val peer: String?) : BridgeAction()
    }

    class BridgeException(message: String, val kind: Kind) : Exception(message) {
        enum class Kind { NOT_CONNECTED, TOO_LARGE, INVALID }
    }

    private val core: GossipCore = GossipCore(
        deviceId = deviceId,
        deviceName = deviceName,
        deviceType = deviceType.wireValue,
        noiseSecret = noiseSecret,
        signingSeed = signingSeed,
        trustJson = trustedDevices.exportCoreSnapshot(),
        disabledFeatures = disabledFeatures,
        clock = null
    )

    // ---- Connections ------------------------------------------------------------------------------------------

    fun accepted(conn: ULong): List<BridgeAction> = call { core.connectionAccepted(conn) }

    fun dial(conn: ULong, target: String, remoteStaticKey: ByteArray, pairingToken: String?): List<BridgeAction> =
        call { core.dial(conn, target, remoteStaticKey, pairingToken) }

    fun bytesReceived(conn: ULong, bytes: ByteArray): List<BridgeAction> = convert(core.bytesReceived(conn, bytes))

    fun connectionClosed(conn: ULong): List<BridgeAction> = convert(core.connectionClosed(conn))

    fun disconnect(deviceId: String): List<BridgeAction> = convert(core.disconnect(deviceId))

    fun tick(): List<BridgeAction> = convert(core.tick())

    fun shouldDial(deviceId: String): Boolean = core.shouldDial(deviceId)

    // ---- Pairing and trust ------------------------------------------------------------------------------------

    fun armPairing(token: String) = core.armPairing(token)

    fun disarmPairing() = core.disarmPairing()

    fun confirmPairing(conn: ULong, accepted: Boolean): List<BridgeAction> = convert(core.confirmPairing(conn, accepted))

    /** Revokes a device: removes its trust, drops its connection and broadcasts `trust.revoke`. */
    fun revokeDevice(deviceId: String): List<BridgeAction> = convert(core.revokeDevice(deviceId))

    /** The `trust.roster_update` for the current roster, targeted at [peer] or broadcast; send it with [send]. */
    fun rosterUpdate(peer: String?): Envelope = appEnvelope(core.rosterUpdate(peer))

    /**
     * Hands the engine the app's current trust table. Needed because the pairing flow edits [TrustedDevicesStore]
     * directly (the QR scanner adds a provisional row before dialing), and provisional rows must be dialable and
     * verifiable but kept out of roster gossip until the other side confirms.
     */
    fun syncTrustFromStore() {
        val json = trustedDevices.exportCoreSnapshot()
        core.setTrust(json, trustedDevices.provisionalIds())
    }

    fun setDisabledFeatures(keys: List<String>) {
        core.setDisabledFeatures(keys)
    }

    // ---- Sending ----------------------------------------------------------------------------------------------

    fun send(envelope: Envelope): List<BridgeAction> = call { core.send(coreEnvelope(envelope)) }

    fun send(envelope: Envelope, raw: ByteArray): List<BridgeAction> = call { core.sendWithRaw(coreEnvelope(envelope), raw) }

    // ---- Conversion -------------------------------------------------------------------------------------------

    private fun call(body: () -> List<CoreAction>): List<BridgeAction> = try {
        convert(body())
    } catch (e: GossipException.NotConnected) {
        throw BridgeException("not connected", BridgeException.Kind.NOT_CONNECTED)
    } catch (e: GossipException.TooLarge) {
        throw BridgeException("message too large", BridgeException.Kind.TOO_LARGE)
    } catch (e: GossipException) {
        throw BridgeException(e.message ?: "engine error", BridgeException.Kind.INVALID)
    }

    private fun convert(actions: List<CoreAction>): List<BridgeAction> = actions.mapNotNull { action ->
        when (action) {
            is CoreAction.Send -> BridgeAction.Send(action.conn, action.bytes)
            is CoreAction.Close -> BridgeAction.Close(action.conn)
            is CoreAction.PeerConnected -> BridgeAction.PeerConnected(action.conn, peerInfo(action.peer), action.newlyPaired)
            is CoreAction.PeerDisconnected -> BridgeAction.PeerDisconnected(action.deviceId)
            is CoreAction.PairingPrompt -> BridgeAction.PairingPrompt(action.conn, peerInfo(action.peer), action.peer.noisePublicKey, action.code)
            is CoreAction.PairingPromptCancelled -> BridgeAction.PairingPromptCancelled(action.conn)
            is CoreAction.Deliver -> BridgeAction.Deliver(appEnvelope(action.envelope), action.raw)
            is CoreAction.Heard -> BridgeAction.Heard(action.deviceId)
            is CoreAction.TrustChanged -> BridgeAction.TrustChanged(action.snapshotJson)
            is CoreAction.DeviceRevoked -> BridgeAction.DeviceRevoked(action.deviceId)
            is CoreAction.ReconcileDue -> BridgeAction.ReconcileDue(action.task, action.peer)
        }
    }

    private fun peerInfo(peer: CorePeerInfo) = HandshakePeerInfo(
        deviceId = peer.deviceId,
        deviceName = peer.deviceName,
        deviceType = DeviceType.fromWire(peer.deviceType),
        signingPublicKey = peer.signingPublicKey
    )

    companion object {
        /** Payloads cross the boundary as JSON text. */
        fun coreEnvelope(e: Envelope): CoreEnvelope = CoreEnvelope(
            v = e.v.toUInt(),
            id = e.id,
            kind = e.type,
            senderId = e.senderId,
            recipientId = e.recipientId,
            broadcast = e.broadcast,
            ttl = e.ttl.toLong(),
            hasRawFollowup = e.hasRawFollowup,
            ts = e.ts,
            payloadJson = Envelope.json.encodeToString(JsonObject.serializer(), e.payload),
            sig = e.sig
        )

        fun appEnvelope(e: CoreEnvelope): Envelope = Envelope(
            v = e.v.toInt(),
            id = e.id,
            type = e.kind,
            senderId = e.senderId,
            recipientId = e.recipientId,
            broadcast = e.broadcast,
            ttl = e.ttl.toInt(),
            hasRawFollowup = e.hasRawFollowup,
            ts = e.ts,
            payload = runCatching { Envelope.json.decodeFromString(JsonObject.serializer(), e.payloadJson) }.getOrDefault(JsonObject(emptyMap())),
            sig = e.sig
        )
    }
}
