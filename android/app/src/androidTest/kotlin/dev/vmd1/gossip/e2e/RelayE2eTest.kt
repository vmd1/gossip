package dev.vmd1.gossip.e2e

import android.util.Base64
import android.util.Log
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import dev.vmd1.gossip.crypto.IdentityKeyStore
import dev.vmd1.gossip.crypto.TrustedDevice
import dev.vmd1.gossip.crypto.TrustedDevicesStore
import dev.vmd1.gossip.protocol.DeviceType
import dev.vmd1.gossip.protocol.Envelope
import dev.vmd1.gossip.transport.EnvelopeHandler
import dev.vmd1.gossip.transport.MessageRouter
import dev.vmd1.gossip.transport.RelayTopicStore
import dev.vmd1.gossip.transport.TransportManager
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.MessageDigest
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicInteger

/**
 * The Android half of the cross-device relay end-to-end test (`mac/GossipTests/EmulatorRelayE2ETests.swift`, run by
 * `mac/scripts/e2e-relay-emulator.sh`). The app's real [TransportManager] and Rust engine run on a real Android runtime, with
 * the real OkHttp relay socket, as a peer the Mac scripts:
 *
 * 1. It scans the Mac's pairing QR over the LAN-style path (the emulator dials the Mac at 10.0.2.2), exactly like
 *    [TransportE2eTest]. That first connection creates the mesh topic and `mesh.topic` carries it across.
 * 2. It then answers the Mac's script, which turns the relay on, takes the LAN away and brings it back, and reports its own
 *    state on request: which peers it sees as relayed or direct, whether the topic was persisted, how often the Mac dropped
 *    out of its peer set, and what happened to the `screen.*`/`control.*` messages that must never cross the relay.
 *
 * Every step logs an `E2E:` line to logcat. The relay is reached at the address the Mac passes (`ws://127.0.0.1:<port>`,
 * which `adb reverse` maps to the host), the same string the Mac uses: the origin is signed into every join.
 */
class RelayE2eTest {
    private val args get() = InstrumentationRegistry.getArguments()
    private fun arg(name: String): String = requireNotNull(args.getString(name)) { "missing instrumentation argument $name" }
    private fun b64(value: String): ByteArray = Base64.decode(value, Base64.NO_WRAP)
    private fun log(message: String) = Log.i("E2E", message)

    @Test
    fun pairOverTheLanThenServeTheRelayScript() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        IdentityKeyStore.ensureInitialized(context)
        val identity = IdentityKeyStore.getInstance(context)
        val trusted = TrustedDevicesStore.getInstance(context)
        for (d in trusted.allDevices()) trusted.remove(d.deviceId)
        val topics = RelayTopicStore.getInstance(context)

        val macId = arg("mac_id")
        val macKey = b64(arg("mac_noise_pub"))
        val macSigning = b64(arg("mac_signing_pub"))
        val host = args.getString("mac_host") ?: "10.0.2.2"
        val port = arg("mac_port").toInt()

        val errors = ConcurrentLinkedQueue<String>()
        val screenDelivered = AtomicInteger()
        val screenSendThrew = AtomicInteger()
        val peerDrops = AtomicInteger()
        val router = MessageRouter()
        val transport = TransportManager(
            context, identity, trusted, router, deviceName = "E2E Emulator", deviceType = DeviceType.ANDROID_PHONE,
            relayTopicStore = topics
        )
        transport.setLanGraceMs(1_000) // dial through the relay soon after the LAN link is gone
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val finish = CompletableDeferred<Unit>()

        fun fail(message: String) { errors.add(message); log("ERROR $message") }
        fun reply(type: String, to: String, payload: JsonObject) {
            scope.launch {
                runCatching { transport.send(Envelope(type = type, senderId = identity.deviceId, recipientId = to, payload = payload)) }
                    .onFailure { fail("send $type failed: $it") }
            }
        }

        // How often the Mac left our peer set (direct or relayed): switching from the relay to the LAN must not count.
        scope.launch {
            var present = false
            transport.peerDeviceIds.collect { ids ->
                val now = macId in ids
                if (present && !now) { peerDrops.incrementAndGet(); log("the Mac left the peer set") }
                present = now
            }
        }

        router.register("e2e.", EnvelopeHandler { e ->
            log("handling ${e.type} from ${e.senderId}")
            try {
                when (e.type) {
                    "e2e.ping" -> reply("e2e.pong", e.senderId, JsonObject(e.payload + ("seenBy" to JsonPrimitive("android"))))
                    "e2e.query" -> {
                        val saved = topics.load()
                        reply("e2e.state", e.senderId, buildJsonObject {
                            put("direct", JsonArray(transport.connectedDeviceIds.value.sorted().map { JsonPrimitive(it) }))
                            put("relayed", JsonArray(transport.relayedDeviceIds.value.sorted().map { JsonPrimitive(it) }))
                            put("isRelayed", JsonPrimitive(transport.isRelayed(e.senderId)))
                            put("topicSaved", JsonPrimitive(saved != null))
                            put("topicSecretB64", JsonPrimitive(saved?.let { Base64.encodeToString(it.secret, Base64.NO_WRAP) } ?: ""))
                            put("relayStatus", JsonPrimitive(transport.relayStatus.value))
                            put("relayIdle", JsonPrimitive(transport.relayIdle.value))
                            put("peerDrops", JsonPrimitive(peerDrops.get()))
                            put("screenDelivered", JsonPrimitive(screenDelivered.get()))
                            put("screenSendThrew", JsonPrimitive(screenSendThrew.get()))
                        })
                    }
                    "e2e.sendraw" -> scope.launch {
                        val raw = ByteArray((e.payload["size"] as JsonPrimitive).content.toInt()) { (it * 31 + 7).toByte() }
                        runCatching {
                            transport.send(
                                Envelope(type = "e2e.rawfromandroid", senderId = identity.deviceId, recipientId = e.senderId, hasRawFollowup = true,
                                    payload = buildJsonObject { put("size", JsonPrimitive(raw.size)) }),
                                raw
                            )
                        }.onFailure { fail("sendraw failed: $it") }
                    }
                    // Try to push screen.* and control.* at the Mac: both must be refused locally while the link is relayed.
                    "e2e.sendscreen" -> scope.launch {
                        for (type in listOf("screen.start", "control.session_start")) {
                            try {
                                transport.send(Envelope(type = type, senderId = identity.deviceId, recipientId = e.senderId, payload = JsonObject(emptyMap())))
                            } catch (t: IllegalStateException) {
                                screenSendThrew.incrementAndGet()
                            }
                        }
                    }
                    "e2e.relay_on" -> transport.setRelayEnabled(true, e.payload["origin"]!!.jsonPrimitive.content)
                    "e2e.relay_off" -> transport.setRelayEnabled(false, null)
                    // Take the LAN away from this side: stop listening and drop the direct link, as walking out of Wi-Fi would.
                    "e2e.lan_off" -> scope.launch { transport.stopListening(); transport.disconnect(e.senderId) }
                    "e2e.lan_on" -> transport.listen(discover = false)
                    "e2e.finish" -> finish.complete(Unit)
                }
            } catch (t: Throwable) {
                fail("handler for ${e.type} threw $t")
            }
        })
        router.register("screen.", EnvelopeHandler { screenDelivered.incrementAndGet() })
        router.register("control.", EnvelopeHandler { screenDelivered.incrementAndGet() })
        transport.onRawFrameReceived = { envelope, raw ->
            val digest = Base64.encodeToString(MessageDigest.getInstance("SHA-256").digest(raw), Base64.NO_WRAP)
            log("raw frame ${raw.size} bytes from ${envelope.senderId}")
            reply("e2e.rawhash", envelope.senderId, buildJsonObject {
                put("sha256", JsonPrimitive(digest))
                put("size", JsonPrimitive(raw.size))
                put("forId", JsonPrimitive(envelope.id))
            })
        }

        // No NSD discovery in this test: nothing on the Android side dials the LAN by itself, only the scripted scan below.
        transport.listen(discover = false)

        // ---- The scan, over the LAN-style path (the emulator dials its host). ----
        trusted.markProvisional(macId)
        trusted.addDevice(TrustedDevice(macId, macKey, arg("mac_name"), DeviceType.MAC, System.currentTimeMillis(), signingPublicKey = macSigning))
        val firstFromMac = async { transport.incoming.first { it.senderId == macId } }
        transport.connect(host, port, macKey, macId, pairingToken = arg("token"))
        withTimeout(60_000) { firstFromMac.await() }
        trusted.clearProvisional(macId)
        log("paired; code=${transport.pairingCodeFor(macKey)}")

        reply("e2e.hello", macId, buildJsonObject {
            put("pairingCode", JsonPrimitive(transport.pairingCodeFor(macKey)))
            put("deviceId", JsonPrimitive(identity.deviceId))
            put("noisePublicKey", JsonPrimitive(Base64.encodeToString(identity.x25519KeyPair.publicKey, Base64.NO_WRAP)))
            put("signingPublicKey", JsonPrimitive(Base64.encodeToString(identity.ed25519PublicKey, Base64.NO_WRAP)))
        })

        withTimeout(15 * 60_000L) { finish.await() }
        log("finished the Mac script")
        transport.shutdown()
        assertTrue("errors: ${errors.toList()}", errors.isEmpty())
    }
}
