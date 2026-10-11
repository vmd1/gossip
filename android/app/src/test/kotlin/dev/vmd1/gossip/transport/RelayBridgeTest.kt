package dev.vmd1.gossip.transport

import dev.vmd1.gossip.crypto.FakeSharedPreferences
import dev.vmd1.gossip.crypto.TrustedDevice
import dev.vmd1.gossip.crypto.TrustedDevicesStore
import dev.vmd1.gossip.protocol.DeviceType
import dev.vmd1.gossip.transport.CoreBridge.BridgeAction
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The relay half of [CoreBridge]: how the engine's relay calls and actions map through the Kotlin bindings (the relay
 * protocol and dial policy themselves are tested in `desktop/core`, `tests/relay_engine.rs`). Two real engines are paired
 * over an in-memory link, which is what creates the mesh topic.
 */
class RelayBridgeTest {
    private class Peer(val name: String, val type: DeviceType) {
        val identity = uniffi.gossip_ffi.generateIdentity()
        val deviceId = identity.deviceId
        val store = TrustedDevicesStore(FakeSharedPreferences())
        val bridge = CoreBridge(identity.deviceId, identity.noiseSecret, identity.signingSeed, name, type, store, emptyList())
        val events = mutableListOf<BridgeAction>()
        fun row() = TrustedDevice(deviceId, identity.noisePublicKey, name, type, 1L, signingPublicKey = identity.signingPublicKey)
    }

    private fun pump(links: MutableMap<String, Pair<Peer, ULong>>, origin: Peer, actions: List<BridgeAction>) {
        val queue = ArrayDeque(actions.map { origin to it })
        while (queue.isNotEmpty()) {
            val (peer, action) = queue.removeFirst()
            when (action) {
                is BridgeAction.Send -> links["${peer.name}:${action.conn}"]?.let { (other, otherConn) ->
                    other.bridge.bytesReceived(otherConn, action.bytes).forEach { queue.addLast(other to it) }
                }
                is BridgeAction.TrustChanged -> { peer.store.importCoreSnapshot(action.snapshotJson); peer.events.add(action) }
                else -> peer.events.add(action)
            }
        }
    }

    /** The scan flow, as `CoreBridgeTest` does it. */
    private fun pair(shower: Peer, scanner: Peer) {
        val links = mutableMapOf<String, Pair<Peer, ULong>>()
        shower.bridge.armPairing("t")
        scanner.store.markProvisional(shower.deviceId)
        scanner.store.addDevice(shower.row())
        scanner.bridge.syncTrustFromStore()
        links["${scanner.name}:1"] = shower to 2uL
        links["${shower.name}:2"] = scanner to 1uL
        pump(links, shower, shower.bridge.accepted(2uL))
        pump(links, scanner, scanner.bridge.dial(1uL, shower.deviceId, shower.identity.noisePublicKey, "t"))
        val prompt = shower.events.filterIsInstance<BridgeAction.PairingPrompt>().last()
        pump(links, shower, shower.bridge.confirmPairing(prompt.conn, true))
        scanner.store.clearProvisional(shower.deviceId)
        scanner.bridge.syncTrustFromStore()
    }

    private fun topics(peer: Peer) = peer.events.filterIsInstance<BridgeAction.TopicChanged>()

    @Test
    fun theFirstConnectionCreatesTheTopicAndBothSidesReportIt() {
        val phone = Peer("phone", DeviceType.ANDROID_PHONE)
        val mac = Peer("mac", DeviceType.MAC)
        pair(shower = mac, scanner = phone)
        val a = topics(phone).last()
        val b = topics(mac).last()
        assertEquals(32, a.secret.size)
        assertArrayEquals("both sides converge on the same secret", a.secret, b.secret)
        assertEquals(a.epoch, b.epoch)
    }

    @Test
    fun enablingTheRelayWithATopicConnectsAndDisablingClosesTheSocket() {
        val phone = Peer("phone", DeviceType.ANDROID_PHONE)
        val mac = Peer("mac", DeviceType.MAC)
        pair(shower = mac, scanner = phone)
        assertEquals("disabled", phone.bridge.relayStatus())

        val connect = phone.bridge.relayConfigure(true, "ws://127.0.0.1:8099").filterIsInstance<BridgeAction.RelayConnect>().single()
        assertTrue("the engine appends the relay path to the origin: ${connect.url}", connect.url.startsWith("ws://127.0.0.1:8099") && connect.url.endsWith("/connect"))
        assertEquals("connecting", phone.bridge.relayStatus())

        // The socket failing by itself is reported; the engine backs off and says it is disconnected.
        phone.bridge.relaySocketClosed()
        assertEquals("disconnected", phone.bridge.relayStatus())

        phone.bridge.relayConfigure(false, "")
        assertEquals("disabled", phone.bridge.relayStatus())
        assertFalse(phone.bridge.isRelayed(mac.deviceId))
    }

    @Test
    fun aPersistedTopicLoadedWithSetTopicAllowsTheRelayWithoutAnyLanConnection() {
        val phone = Peer("phone", DeviceType.ANDROID_PHONE)
        val mac = Peer("mac", DeviceType.MAC)
        pair(shower = mac, scanner = phone)
        val saved = topics(phone).last()

        val fresh = Peer("phone2", DeviceType.ANDROID_PHONE)
        assertTrue("no topic yet: nothing to connect to", fresh.bridge.relayConfigure(true, "ws://127.0.0.1:8099").none { it is BridgeAction.RelayConnect })
        assertEquals("no_topic", fresh.bridge.relayStatus())
        val actions = fresh.bridge.setTopic(saved.secret, saved.epoch.toLong())
        // Either set_topic or the next tick connects; both are fine, but the topic must be usable now.
        val connects = (actions + fresh.bridge.tick()).filterIsInstance<BridgeAction.RelayConnect>()
        assertEquals(1, connects.size)
        assertEquals("connecting", fresh.bridge.relayStatus())
    }
}
