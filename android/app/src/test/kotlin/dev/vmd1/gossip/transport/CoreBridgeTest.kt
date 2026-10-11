package dev.vmd1.gossip.transport

import dev.vmd1.gossip.crypto.FakeSharedPreferences
import dev.vmd1.gossip.crypto.TrustedDevice
import dev.vmd1.gossip.crypto.TrustedDevicesStore
import dev.vmd1.gossip.protocol.DeviceType
import dev.vmd1.gossip.protocol.Envelope
import dev.vmd1.gossip.transport.CoreBridge.BridgeAction
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Drives two real Rust engines through [CoreBridge], wired together in memory, to check everything the app relies on that
 * is not protocol logic (that is tested in `desktop/core`): envelope and payload conversion, the trust snapshot round trip
 * into [TrustedDevicesStore], the provisional-row pairing flow only Android uses, and reconnect and revocation as the app
 * sees them. The engine runs through JNA from a host build of `libgossip_ffi` (see `app/build.gradle.kts`).
 */
class CoreBridgeTest {
    private class Peer(val name: String, val type: DeviceType, disabled: List<String> = emptyList(), identity: uniffi.gossip_ffi.NewIdentity = uniffi.gossip_ffi.generateIdentity(), val store: TrustedDevicesStore = TrustedDevicesStore(FakeSharedPreferences())) {
        val identity = identity
        val deviceId = identity.deviceId
        val bridge = CoreBridge(identity.deviceId, identity.noiseSecret, identity.signingSeed, name, type, store, disabled)
        val events = mutableListOf<BridgeAction>()

        fun delivered(type: String): List<Envelope> = events.filterIsInstance<BridgeAction.Deliver>().map { it.envelope }.filter { it.type == type }
        fun prompt(): BridgeAction.PairingPrompt? = events.filterIsInstance<BridgeAction.PairingPrompt>().lastOrNull()
        fun row(): TrustedDevice = TrustedDevice(deviceId, identity.noisePublicKey, name, type, 1L, signingPublicKey = identity.signingPublicKey)
    }

    private class Wire {
        val links = mutableMapOf<String, Pair<Peer, ULong>>()
        var next = 1uL

        fun pump(origin: Peer, actions: List<BridgeAction>) {
            val queue = ArrayDeque(actions.map { origin to it })
            while (queue.isNotEmpty()) {
                val (peer, action) = queue.removeFirst()
                when (action) {
                    is BridgeAction.Send -> links["${peer.name}:${action.conn}"]?.let { (other, otherConn) ->
                        other.bridge.bytesReceived(otherConn, action.bytes).forEach { queue.addLast(other to it) }
                    }
                    is BridgeAction.Close -> links.remove("${peer.name}:${action.conn}")?.let { (other, otherConn) ->
                        links.remove("${other.name}:$otherConn")
                        other.bridge.connectionClosed(otherConn).forEach { queue.addLast(other to it) }
                    }
                    is BridgeAction.TrustChanged -> {
                        peer.store.importCoreSnapshot(action.snapshotJson) // what TransportManager does under its lock
                        peer.events.add(action)
                    }
                    else -> peer.events.add(action)
                }
            }
        }

        fun open(dialer: Peer, listener: Peer, pairingToken: String? = null) {
            val a = next
            val b = next + 1uL
            next += 2uL
            links["${dialer.name}:$a"] = listener to b
            links["${listener.name}:$b"] = dialer to a
            pump(listener, listener.bridge.accepted(b))
            pump(dialer, dialer.bridge.dial(a, listener.deviceId, listener.identity.noisePublicKey, pairingToken))
        }
    }

    /** The real Android scan flow: the scanner adds a provisional row, hands the engine its table, dials, and the device
     *  showing the QR confirms. */
    private fun pairByScanning(wire: Wire, shower: Peer, scanner: Peer) {
        shower.bridge.armPairing("token-1")
        scanner.store.markProvisional(shower.deviceId)
        scanner.store.addDevice(shower.row())
        scanner.bridge.syncTrustFromStore()
        wire.open(scanner, shower, "token-1")
        val prompt = shower.prompt()
        assertNotNull("the device showing the QR must be asked to confirm", prompt)
        assertEquals(scanner.deviceId, prompt!!.peer.deviceId)
        wire.pump(shower, shower.bridge.confirmPairing(prompt.conn, true))
        scanner.store.clearProvisional(shower.deviceId)
        scanner.bridge.syncTrustFromStore()
    }

    @Test
    fun scanningFlowPairsAndDeliversPayloadsIntact() {
        val wire = Wire()
        val phone = Peer("phone", DeviceType.ANDROID_PHONE)
        val mac = Peer("mac", DeviceType.MAC)
        pairByScanning(wire, shower = mac, scanner = phone)
        assertTrue(wire.links.isNotEmpty())

        val payload = buildJsonObject {
            put("title", JsonPrimitive("Héllo \"q\" \\ 日本 😀"))
            put("count", JsonPrimitive(42))
            put("big", JsonPrimitive(9_007_199_254_740_991L))
            put("neg", JsonPrimitive(-7))
            put("flag", JsonPrimitive(true))
            put("list", buildJsonArray { add(JsonPrimitive(1)); add(JsonPrimitive("two")); add(buildJsonObject { put("k", JsonArray(emptyList())) }) })
        }
        val sent = Envelope(type = "notification.posted", senderId = phone.deviceId, broadcast = true, payload = payload)
        wire.pump(phone, phone.bridge.send(sent))

        val received = mac.delivered("notification.posted").single()
        assertEquals("payload survives the trip through the engine exactly", payload, received.payload)
        assertEquals(phone.deviceId, received.senderId)
        assertEquals(sent.id, received.id)
        assertNotNull("the engine signed it", received.sig)

        // And back: the confirmed device's first message verifies on the scanner because the provisional row carried its key.
        wire.pump(mac, mac.bridge.send(Envelope(type = "dnd.update", senderId = mac.deviceId, broadcast = true, payload = buildJsonObject { put("enabled", JsonPrimitive(true)) })))
        assertEquals(1, phone.delivered("dnd.update").size)
    }

    @Test
    fun aProvisionalRowIsDialableButNeverAnnouncedUntilConfirmed() {
        val wire = Wire()
        val phone = Peer("phone", DeviceType.ANDROID_PHONE)
        val mac = Peer("mac", DeviceType.MAC)
        mac.bridge.armPairing("token-1")
        phone.store.markProvisional(mac.deviceId)
        phone.store.addDevice(mac.row())
        phone.bridge.syncTrustFromStore()

        fun announced(): Set<String> =
            phone.bridge.rosterUpdate(null).payload["devices"]!!.jsonArray.map { (it as JsonObject)["deviceId"]!!.jsonPrimitive.content }.toSet()
        assertEquals("only the phone itself while the pairing is unconfirmed", setOf(phone.deviceId), announced())

        wire.open(phone, mac, "token-1")
        val prompt = mac.prompt()
        assertNotNull(prompt)
        wire.pump(mac, mac.bridge.confirmPairing(prompt!!.conn, true))
        phone.store.clearProvisional(mac.deviceId)
        phone.bridge.syncTrustFromStore()
        assertEquals("once confirmed the row is announced like any other", setOf(phone.deviceId, mac.deviceId), announced())
    }

    @Test
    fun trustSurvivesARestartAndReconnectsWithoutAPrompt() {
        val wire = Wire()
        val phone = Peer("phone", DeviceType.ANDROID_PHONE)
        val mac = Peer("mac", DeviceType.MAC)
        pairByScanning(wire, shower = mac, scanner = phone)

        // The shower learned the scanner through the engine; the app store got it with the handshake's signing key.
        val row = mac.store.getDevice(phone.deviceId)
        assertNotNull(row)
        assertArrayEquals(phone.identity.noisePublicKey, row!!.publicKey)
        assertArrayEquals(phone.identity.signingPublicKey, row.signingPublicKey)

        // A restart: new engines built from the same persisted stores and identities.
        val wire2 = Wire()
        val phone2 = Peer("phone", DeviceType.ANDROID_PHONE, identity = phone.identity, store = phone.store)
        val mac2 = Peer("mac", DeviceType.MAC, identity = mac.identity, store = mac.store)
        wire2.open(mac2, phone2)
        assertNull(mac2.prompt())
        assertNull(phone2.prompt())
        assertTrue(mac2.events.any { it is BridgeAction.PeerConnected })
        assertTrue(phone2.events.any { it is BridgeAction.PeerConnected })
    }

    @Test
    fun appOnlyFieldsSurviveEngineSnapshots() {
        val wire = Wire()
        val phone = Peer("phone", DeviceType.ANDROID_PHONE)
        val mac = Peer("mac", DeviceType.MAC)
        pairByScanning(wire, shower = mac, scanner = phone)
        mac.store.setFallbackHost(phone.deviceId, "100.64.0.9")
        mac.store.setBeaconKey(phone.deviceId, ByteArray(32) { 7 })

        // The engine reports another change (a roster introduces a stranger): the existing row keeps its app-only data.
        val stranger = uniffi.gossip_ffi.generateIdentity()
        val roster = Envelope(
            type = "trust.roster_update", senderId = phone.deviceId, recipientId = mac.deviceId,
            payload = buildJsonObject {
                put("devices", buildJsonArray {
                    add(buildJsonObject {
                        put("deviceId", JsonPrimitive(stranger.deviceId))
                        put("publicKey", JsonPrimitive(java.util.Base64.getEncoder().encodeToString(stranger.noisePublicKey)))
                        put("deviceName", JsonPrimitive("Tablet"))
                        put("deviceType", JsonPrimitive("android-tablet"))
                    })
                })
            }
        )
        wire.pump(phone, phone.bridge.send(roster))

        assertNotNull("gossip introduced the tablet through the engine", mac.store.getDevice(stranger.deviceId))
        val kept = mac.store.getDevice(phone.deviceId)!!
        assertEquals("100.64.0.9", kept.fallbackHost)
        assertNotNull(kept.beaconKey)
    }

    @Test
    fun revokingADeviceRemovesItAndLeavesATombstone() {
        val wire = Wire()
        val phone = Peer("phone", DeviceType.ANDROID_PHONE)
        val mac = Peer("mac", DeviceType.MAC)
        pairByScanning(wire, shower = mac, scanner = phone)
        wire.pump(mac, mac.bridge.revokeDevice(phone.deviceId))

        assertFalse("the app store no longer trusts it", mac.store.isTrusted(phone.deviceId))
        assertNotNull("a tombstone keeps gossip from reviving it", mac.store.revokedAt(phone.deviceId))
        assertTrue("the connection was dropped", mac.events.any { it is BridgeAction.PeerDisconnected })
    }

    @Test
    fun aFeatureTurnedOffNeverReachesTheApp() {
        val wire = Wire()
        val phone = Peer("phone", DeviceType.ANDROID_PHONE)
        val mac = Peer("mac", DeviceType.MAC, disabled = listOf("clipboard"))
        pairByScanning(wire, shower = mac, scanner = phone)
        fun text(type: String) = Envelope(type = type, senderId = phone.deviceId, broadcast = true, payload = buildJsonObject { put("enabled", JsonPrimitive(true)) })
        wire.pump(phone, phone.bridge.send(text("clipboard.update")))
        wire.pump(phone, phone.bridge.send(text("dnd.update")))
        assertTrue(mac.delivered("clipboard.update").isEmpty())
        assertEquals(1, mac.delivered("dnd.update").size)
        mac.bridge.setDisabledFeatures(emptyList())
        wire.pump(phone, phone.bridge.send(text("clipboard.update")))
        assertEquals("re-enabling takes effect immediately", 1, mac.delivered("clipboard.update").size)
    }

    @Test
    fun sendingWithNobodyConnectedIsAnErrorAndAFractionIsRefused() {
        val lonely = Peer("lonely", DeviceType.ANDROID_PHONE)
        try {
            lonely.bridge.send(Envelope(type = "dnd.update", senderId = lonely.deviceId, broadcast = true))
            fail("expected an error")
        } catch (e: CoreBridge.BridgeException) {
            assertEquals(CoreBridge.BridgeException.Kind.NOT_CONNECTED, e.kind)
        }
        val wire = Wire()
        val a = Peer("a", DeviceType.ANDROID_PHONE)
        val b = Peer("b", DeviceType.MAC)
        pairByScanning(wire, shower = b, scanner = a)
        try {
            a.bridge.send(Envelope(type = "battery.update", senderId = a.deviceId, broadcast = true, payload = buildJsonObject { put("level", JsonPrimitive(0.5)) }))
            fail("a fractional number cannot be signed")
        } catch (e: CoreBridge.BridgeException) {
            assertEquals(CoreBridge.BridgeException.Kind.INVALID, e.kind)
        }
    }

    @Test
    fun rawFollowupArrivesWithItsEnvelope() {
        val wire = Wire()
        val phone = Peer("phone", DeviceType.ANDROID_PHONE)
        val mac = Peer("mac", DeviceType.MAC)
        pairByScanning(wire, shower = mac, scanner = phone)
        val png = ByteArray(2000) { (it % 251).toByte() }
        val env = Envelope(type = "clipboard.update", senderId = phone.deviceId, broadcast = true, hasRawFollowup = true, payload = buildJsonObject { put("kind", JsonPrimitive("image")) })
        wire.pump(phone, phone.bridge.send(env, png))
        val raw = mac.events.filterIsInstance<BridgeAction.Deliver>().last { it.envelope.type == "clipboard.update" }.raw
        assertArrayEquals(png, raw)
    }
}
