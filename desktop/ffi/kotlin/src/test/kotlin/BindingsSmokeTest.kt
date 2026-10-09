import uniffi.gossip_ffi.*
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Smoke test of the generated Kotlin bindings; mirrors ffi/tests/swift/main.swift. */
class BindingsSmokeTest {
    private class FixedClock : Clock {
        var now = 1_760_000_000_000L
        override fun nowMs(): Long = now
    }

    private class Node(val core: GossipCore, val id: NewIdentity) {
        val events = mutableListOf<Action>()
    }

    private class Net {
        val nodes = mutableListOf<Node>()
        val links = mutableMapOf<String, Pair<Int, ULong>>()
        var nextConn = 1uL
        val clock = FixedClock()

        fun add(name: String, type: String, trust: String? = null, identity: NewIdentity = generateIdentity()): Int {
            val core = GossipCore(identity.deviceId, name, type, identity.noiseSecret, identity.signingSeed, trust, emptyList(), clock)
            nodes += Node(core, identity)
            return nodes.size - 1
        }

        fun pump(node: Int, actions: List<Action>) {
            val queue = ArrayDeque(actions.map { node to it })
            while (queue.isNotEmpty()) {
                val (n, action) = queue.removeFirst()
                when (action) {
                    is Action.Send -> links["$n:${action.conn}"]?.let { (peer, peerConn) ->
                        nodes[peer].core.bytesReceived(peerConn, action.bytes).forEach { queue += peer to it }
                    }
                    is Action.Close -> links.remove("$n:${action.conn}")?.let { (peer, peerConn) ->
                        links.remove("$peer:$peerConn")
                        nodes[peer].core.connectionClosed(peerConn).forEach { queue += peer to it }
                    }
                    else -> nodes[n].events += action
                }
            }
        }

        fun open(dialer: Int, listener: Int, pairingToken: String? = null) {
            val a = nextConn
            val b = nextConn + 1uL
            nextConn += 2uL
            links["$dialer:$a"] = listener to b
            links["$listener:$b"] = dialer to a
            pump(listener, nodes[listener].core.connectionAccepted(b))
            pump(dialer, nodes[dialer].core.dial(a, nodes[listener].id.deviceId, nodes[listener].id.noisePublicKey, pairingToken))
        }

        fun prompt(node: Int): Pair<ULong, String>? =
            nodes[node].events.filterIsInstance<Action.PairingPrompt>().lastOrNull()?.let { it.conn to it.code }

        fun delivered(node: Int, kind: String): List<Envelope> =
            nodes[node].events.filterIsInstance<Action.Deliver>().map { it.envelope }.filter { it.kind == kind }
    }

    @Test
    fun pairMessagePersistAndReconnect() {
        val net = Net()
        val mac = net.add("Test Mac", "mac")
        val phone = net.add("Test Phone", "android-phone")

        net.nodes[mac].core.armPairing("kotlin-token")
        net.open(dialer = phone, listener = mac, pairingToken = "kotlin-token")
        val (macConn, macCode) = assertNotNull(net.prompt(mac), "mac must be asked to confirm")
        val (phoneConn, phoneCode) = assertNotNull(net.prompt(phone), "phone must be asked to confirm")
        assertEquals(macCode, phoneCode)
        assertEquals(macCode, pairingCode(net.nodes[mac].id.noisePublicKey, net.nodes[phone].id.noisePublicKey))
        assertTrue(pairingEntryMatches(macCode.replace(" ", ""), macCode))
        net.pump(mac, net.nodes[mac].core.confirmPairing(macConn, true))
        net.pump(phone, net.nodes[phone].core.confirmPairing(phoneConn, true))
        assertTrue(net.nodes[mac].core.isConnected(net.nodes[phone].id.deviceId))
        assertEquals(listOf(net.nodes[mac].id.deviceId), net.nodes[phone].core.connectedPeers())

        // Relay and mesh topic: pairing minted a topic on both sides; configure/status/connect round trip.
        assertEquals(1uL, net.nodes[mac].core.topicEpoch())
        assertEquals(1uL, net.nodes[phone].core.topicEpoch())
        val minted = (net.nodes[mac].events + net.nodes[phone].events).filterIsInstance<Action.TopicChanged>().first { it.epoch == 1uL }
        assertEquals(32, minted.secret.size)
        assertEquals("disabled", net.nodes[mac].core.relayStatus())
        val connect = net.nodes[mac].core.relayConfigure(true, "wss://relay.example.test").filterIsInstance<Action.RelayConnect>().single()
        assertEquals("wss://relay.example.test/connect", connect.url)
        assertEquals("connecting", net.nodes[mac].core.relayStatus())
        net.nodes[mac].core.relaySocketOpened()
        val challenge = """{"type":"relay.challenge","nonce":"gIGCg4SFhoeIiYqLjI2Oj5CRkpOUlZaXmJmam5ydnp8=","powBits":0}"""
        val join = net.nodes[mac].core.relayTextReceived(challenge).filterIsInstance<Action.RelaySendText>().single()
        assertTrue(join.text.contains("relay.join"))
        assertTrue(net.nodes[mac].core.relayConfigure(false, "").any { it is Action.RelayClose })
        assertEquals("disabled", net.nodes[mac].core.relayStatus())
        assertFalse(net.nodes[mac].core.isRelayed(net.nodes[phone].id.deviceId))
        net.nodes[mac].core.setTopic(ByteArray(32) { 7 }, 5uL)
        assertEquals(5uL, net.nodes[mac].core.topicEpoch())
        assertFailsWith<GossipException.InvalidArgument> { net.nodes[mac].core.setTopic(byteArrayOf(1), 1uL) }

        net.pump(phone, net.nodes[phone].core.sendMessage("dnd.update", null, """{"sourceDeviceId":"x","enabled":true,"isInitialSync":false}"""))
        val got = net.delivered(mac, "dnd.update")
        assertEquals(1, got.size)
        assertEquals(net.nodes[phone].id.deviceId, got.single().senderId)
        assertTrue(got.single().payloadJson.contains("\"enabled\":true"))

        val env = net.nodes[phone].core.newEnvelope("clipboard.update").copy(broadcast = true)
        net.pump(phone, net.nodes[phone].core.sendWithRaw(env, byteArrayOf(1, 2, 3, 4, 5)))
        val raw = net.nodes[mac].events.filterIsInstance<Action.Deliver>().last { it.envelope.kind == "clipboard.update" }.raw
        assertContentEquals(byteArrayOf(1, 2, 3, 4, 5), raw)

        net.nodes[mac].core.setDisabledFeatures(listOf("dnd"))
        val before = net.delivered(mac, "dnd.update").size
        net.pump(phone, net.nodes[phone].core.sendMessage("dnd.update", null, """{"enabled":false}"""))
        assertEquals(before, net.delivered(mac, "dnd.update").size, "a disabled feature does not deliver")
        assertTrue("dnd" in featureKeys())
        assertEquals("dnd", featureForMessageType("dnd.update"))

        assertFailsWith<GossipException.InvalidArgument> { net.nodes[mac].core.sendMessage("x.y", null, "[1,2]") }
        assertFailsWith<GossipException.InvalidArgument> { net.nodes[mac].core.dial(99uL, "t", byteArrayOf(1, 2, 3), null) }

        // Persist and restore: reconnect from the trust snapshots with no prompt.
        val macTrust = net.nodes[mac].core.trustJson()
        val phoneTrust = net.nodes[phone].core.trustJson()
        assertTrue(macTrust.contains(net.nodes[phone].id.deviceId))
        val net2 = Net()
        val mac2 = net2.add("Test Mac", "mac", macTrust, net.nodes[mac].id)
        val phone2 = net2.add("Test Phone", "android-phone", phoneTrust, net.nodes[phone].id)
        net2.open(dialer = mac2, listener = phone2)
        assertNull(net2.prompt(mac2))
        assertNull(net2.prompt(phone2))
        assertTrue(net2.nodes[mac2].core.isConnected(net.nodes[phone].id.deviceId))
        assertTrue(net2.nodes[phone2].core.isConnected(net.nodes[mac].id.deviceId))

        // Time flows through the injected clock.
        net2.clock.now += 70_000
        net2.pump(mac2, net2.nodes[mac2].core.tick())
        assertFalse(net2.nodes[mac2].core.isConnected(net.nodes[phone].id.deviceId))
    }

    @Test
    fun standaloneHelpers() {
        val id = generateIdentity()
        assertEquals(32, id.noiseSecret.size)
        assertContentEquals(id.noisePublicKey, noisePublicKey(id.noiseSecret))
        assertContentEquals(id.signingPublicKey, signingPublicKey(id.signingSeed))
        val key = ByteArray(32) { (it + 1).toByte() }
        assertEquals(8, bleBeaconTag(key, 0uL).size)
        assertEquals(3, bleAcceptableTags(key, 600uL).size)
        val a = StreamCipher(StreamProfile.SCREEN, key, "s", true)
        val b = StreamCipher(StreamProfile.SCREEN, key, "s", false)
        val sealed = a.seal("hello".toByteArray())
        assertContentEquals("hello".toByteArray(), b.open(sealed))
        assertFailsWith<GossipException> { b.open(sealed) }
        assertEquals("aGk=", base64Encode("hi".toByteArray()))
    }

    @Test
    fun featureStateMachines() {
        val a = Dnd(null)
        val b = Dnd(true)
        fun payload(fx: List<DndEffect>) = fx.filterIsInstance<DndEffect.Send>().single().message.payloadJson
        val pa = payload(a.initialSync("a"))
        val pb = payload(b.initialSync("b"))
        a.onUpdate(pb, 0)
        b.onUpdate(pa, 0)
        assertEquals(true, a.expected())
        assertEquals(true, b.expected())

        val battery = Battery()
        val alerts = listOf(19, 19, 18).sumOf { level ->
            battery.onUpdate("p", """{"level":$level,"isCharging":false}""").count { it is BatteryEffect.LowBattery }
        }
        assertEquals(1, alerts)
        assertEquals(18.toUByte(), battery.stateOf("p")?.level)

        val ring = Ring()
        val start = ringPayload("start", "r1")
        assertTrue(ring.onRing("peer", start, 0).isNotEmpty() && ring.isRinging())
        assertTrue(ring.onRing("peer", start, 1).isEmpty(), "duplicate start is a no-op")
        assertTrue(ring.stopRinging().isNotEmpty() && !ring.isRinging())

        val clip = ClipboardGuard()
        assertNotNull(clip.outgoingText("m", "hi", false))
        assertNull(clip.outgoingText("m", "hi", false), "resync of the same value is suppressed")
        assertNull(clip.outgoingText("m", "secret", true), "sensitive content is never sent")

        val media = CommandGuard()
        val cmd = """{"action":"next","commandId":"c1"}"""
        assertEquals(MediaAction.NEXT, media.accept(cmd)?.action)
        assertNull(media.accept(cmd), "duplicate command ignored")
        val replies = ReplyGuard()
        val reply = notificationReplyPayload("n1", "ok", "a1")
        assertEquals("ok", replies.accept(reply)?.text)
        assertNull(replies.accept(reply), "duplicate reply ignored")

        val lock = LockOnLeave(listOf("phone"))
        assertTrue(lock.nearbyChanged(emptyList(), 0, true, listOf("phone")))
        assertFalse(lock.nearbyChanged(listOf("phone"), 1, true, listOf("phone")))
    }

    @Test
    fun hotspotGatt() {
        val provider = generateIdentity()
        val requester = generateIdentity()
        val req = hotspotRequestCreate(requester.deviceId, true, newUuid(), 1_000_000L, requester.signingSeed)
        val requesterKey = base64Encode(requester.signingPublicKey)
        assertTrue(hotspotRequestVerify(req, requesterKey))
        assertTrue(hotspotRequestIsFresh(req, 1_060_000L))
        assertFalse(hotspotRequestIsFresh(req, 1_130_000L))
        assertEquals(req.n, hotspotRequestDecode(hotspotRequestEncode(req))?.n)

        val shared = assertNotNull(hotspotDeriveSharedKey(provider.noiseSecret, requester.noisePublicKey))
        assertContentEquals(shared, hotspotDeriveSharedKey(requester.noiseSecret, provider.noisePublicKey))
        val status = hotspotStatusCreate(provider.deviceId, true, "n", provider.signingSeed, HotspotCredentials("Net", "pw", shared, randomBytes(12u)))
        assertTrue(hotspotStatusVerify(status, base64Encode(provider.signingPublicKey)))
        val login = assertNotNull(hotspotStatusDecrypt(status, shared))
        assertEquals("Net" to "pw", login.ssid to login.passphrase)

        val reassembler = HotspotChunkReassembler()
        var whole: ByteArray? = null
        hotspotEncodeChunks(ByteArray(100) { 7 }).forEach { whole = reassembler.feed(it) }
        assertContentEquals(ByteArray(100) { 7 }, whole)
        val gate = HotspotRequestGate()
        assertTrue(gate.firstUse("x"))
        assertFalse(gate.firstUse("x"))
    }

    @Test
    fun universalControl() {
        val ack = ControlFrame.HelloAck(ControlDisplayInfo(2000u.toUShort(), 1200u.toUShort(), 1u.toUByte(), 0u.toUByte()))
        assertEquals("8107d004b00100", controlFrameEncode(ack).joinToString("") { "%02x".format(it) }, "matches the shared vector")
        assertEquals(ack, controlFrameDecode(controlFrameEncode(ack)))
        assertNull(controlFrameDecode(byteArrayOf(0x7f)))
        assertEquals(ControlAction.HOME, controlActionForMacKeyCode(18u.toUShort()))

        val layout = ControlLayout(listOf(LocalDisplay("mac", Rect(0.0, 0.0, 1440.0, 900.0))), emptyList())
        val origin = layout.place("tab", Size(800.0, 500.0), Point(1450.0, 20.0), controlSnapDistance(), 0.0)
        assertEquals(Point(1440.0, 0.0), origin)
        val router = PointerRouter(layout, 30.0)
        router.setReadyDevices(listOf("tab"))
        var entered = false
        repeat(10) {
            router.localMoved(Point(5.0, 0.0), Point(1439.5, 300.0)).forEach {
                if (it is PointerAction.Enter) entered = it.deviceId == "tab" && it.edge == ControlEdge.LEFT
            }
        }
        assertTrue(entered)
        assertTrue(router.state() is PointerState.Remote)
        assertTrue(router.forceReturn(null, true).isNotEmpty())
    }

    @Test
    fun relayDirectory() {
        assertEquals("wss://gossip.vmd1.dev", relayDirectoryParse("""{"relayServer":"wss://gossip.vmd1.dev/","x":1}"""))
        assertEquals("wss://relay.example.org", relayDirectoryParse("""{"relayServer":"wss://relay.example.org"}"""))
        assertNull(relayDirectoryParse("""{"relayServer":"https://x.example"}"""))
        val good = """{"relayServer":"wss://a.vmd1.dev"}"""
        val adopt = relayDirectoryDecide(null, good)
        assertEquals(DirectoryAction.ADOPT, adopt.action)
        assertTrue(adopt.changed)
        assertEquals("wss://a.vmd1.dev", adopt.relayServer)
        val keep = relayDirectoryDecide(good, """{"relayServer":"https://evil.com"}""")
        assertEquals(DirectoryAction.KEEP_CACHED, keep.action)
        assertEquals("wss://a.vmd1.dev", keep.relayServer)
        assertNotNull(keep.rejection)
        assertEquals(DirectoryAction.KEEP_CACHED, relayDirectoryDecide(good, null).action)
        assertEquals(DirectoryAction.NO_DIRECTORY, relayDirectoryDecide("junk", null).action)
        val scheduler = RelayDirectoryScheduler.withJitterPermille(0)
        assertTrue(scheduler.shouldPoll(10, 5, null, 0u))
        assertFalse(scheduler.shouldPoll(1_000, 10, 10, 0u))
        assertTrue(scheduler.shouldPoll(10 + 6 * 3_600_000, 10, 10, 0u))
        assertEquals(240_000L, scheduler.backoffMs(3u))
        assertFalse(scheduler.shouldPollAfterConnectFailure(100_000, 10))
    }
}
