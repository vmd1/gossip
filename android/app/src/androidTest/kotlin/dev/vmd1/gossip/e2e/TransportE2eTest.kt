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
import dev.vmd1.gossip.transport.TransportManager
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.FixMethodOrder
import org.junit.Test
import org.junit.runners.MethodSorters
import java.security.MessageDigest
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicInteger

/**
 * The Android half of the end-to-end test against the Mac app (`mac/GossipTests/EmulatorE2ETests.swift`, run by
 * `scripts/e2e-emulator.sh`). It runs the app's real [TransportManager], with the Rust protocol engine loaded through JNA
 * on a real Android runtime, as a scripted peer:
 *
 * 1. It scans the Mac's pairing QR (the Mac passes the payload as instrumentation arguments): adds the provisional row,
 *    dials, and waits for the Mac's first message, exactly as `PairingViewModel` does after discovery.
 * 2. It then serves the Mac's script: echoes pings, hashes raw frames, reports its own state on request, applies feature
 *    toggles, until the Mac says `e2e.finish`.
 * 3. After the Mac revokes it, it checks the Mac refuses it.
 *
 * Every step logs an `E2E:` line to logcat; the Mac side makes the assertions about what it received.
 */
@FixMethodOrder(MethodSorters.NAME_ASCENDING)
class TransportE2eTest {
    private val args get() = InstrumentationRegistry.getArguments()
    private fun arg(name: String): String = requireNotNull(args.getString(name)) { "missing instrumentation argument $name" }
    private fun b64(value: String): ByteArray = Base64.decode(value, Base64.NO_WRAP)
    private fun log(message: String) = Log.i("E2E", message)

    companion object {
        private lateinit var transport: TransportManager
        private lateinit var trusted: TrustedDevicesStore
        private lateinit var identity: IdentityKeyStore
        private val errors = ConcurrentLinkedQueue<String>()
        private val dnd = AtomicInteger()
        private val clipboard = AtomicInteger()
    }

    @Test
    fun test1_pairByScanningThenServeTheMacScript() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        IdentityKeyStore.ensureInitialized(context)
        identity = IdentityKeyStore.getInstance(context)
        trusted = TrustedDevicesStore.getInstance(context)
        for (d in trusted.allDevices()) trusted.remove(d.deviceId)

        val macId = arg("mac_id")
        val macKey = b64(arg("mac_noise_pub"))
        val macSigning = b64(arg("mac_signing_pub"))
        val host = args.getString("mac_host") ?: "10.0.2.2"
        val port = arg("mac_port").toInt()

        val router = MessageRouter()
        transport = TransportManager(context, identity, trusted, router, deviceName = "E2E Emulator", deviceType = DeviceType.ANDROID_PHONE)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val finish = CompletableDeferred<Unit>()

        fun fail(message: String) {
            errors.add(message)
            log("ERROR $message")
        }

        fun reply(type: String, to: String, payload: JsonObject) {
            scope.launch {
                runCatching { transport.send(Envelope(type = type, senderId = identity.deviceId, recipientId = to, payload = payload)) }
                    .onFailure { fail("send $type failed: $it") }
            }
        }

        router.register("e2e.", EnvelopeHandler { e ->
            log("handling ${e.type} from ${e.senderId}")
            try {
            when (e.type) {
                "e2e.ping" -> reply("e2e.pong", e.senderId, JsonObject(e.payload + ("seenBy" to JsonPrimitive("android"))))
                "e2e.query" -> reply("e2e.state", e.senderId, buildJsonObject {
                    put("connected", JsonArray(transport.connectedDeviceIds.value.sorted().map { JsonPrimitive(it) }))
                    put("trusted", JsonArray(trusted.allDevices().map { JsonPrimitive(it.deviceId) }.sortedBy { it.content }))
                    put("macHasSigningKey", JsonPrimitive(trusted.getDevice(e.senderId)?.signingPublicKey != null))
                    put("dnd", JsonPrimitive(dnd.get()))
                    put("clipboard", JsonPrimitive(clipboard.get()))
                })
                "e2e.sendraw" -> scope.launch {
                    // Android -> Mac with a raw follow-up frame: a recognisable pattern the Mac can check.
                    val raw = ByteArray((e.payload["size"] as JsonPrimitive).content.toInt()) { (it * 31 + 7).toByte() }
                    runCatching {
                        transport.send(
                            Envelope(type = "e2e.rawfromandroid", senderId = identity.deviceId, recipientId = e.senderId, hasRawFollowup = true,
                                payload = buildJsonObject { put("size", JsonPrimitive(raw.size)) }),
                            raw
                        )
                    }.onFailure { fail("sendraw failed: $it") }
                }
                "e2e.disable" -> transport.setDisabledFeatures((e.payload["keys"] as JsonArray).map { it.jsonPrimitive.content })
                "e2e.finish" -> finish.complete(Unit)
            }
            } catch (t: Throwable) {
                fail("handler for ${e.type} threw $t")
            }
        })
        // Feature-gated types: the engine drops these before delivery when the feature is off, so these counters are the
        // observable proof that the gate works end to end.
        router.register("dnd.", EnvelopeHandler { dnd.incrementAndGet() })
        router.register("clipboard.", EnvelopeHandler { clipboard.incrementAndGet() })
        transport.onRawFrameReceived = { envelope, raw ->
            val digest = Base64.encodeToString(MessageDigest.getInstance("SHA-256").digest(raw), Base64.NO_WRAP)
            log("raw frame ${raw.size} bytes from ${envelope.senderId}")
            reply("e2e.rawhash", envelope.senderId, buildJsonObject {
                put("sha256", JsonPrimitive(digest))
                put("size", JsonPrimitive(raw.size))
                put("forId", JsonPrimitive(envelope.id))
            })
        }

        transport.listen()

        // ---- The scan: exactly what PairingViewModel does once discovery has found the Mac. ----
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

        withTimeout(10 * 60_000L) { finish.await() }
        log("finished the Mac script")
        assertTrue("errors: ${errors.toList()}", errors.isEmpty())
    }

    @Test
    fun test2_afterTheMacRevokesUsItRefusesOurConnections() = runBlocking {
        val macId = arg("mac_id")
        val macKey = b64(arg("mac_noise_pub"))
        val host = args.getString("mac_host") ?: "10.0.2.2"
        val port = arg("mac_port").toInt()

        // The Mac dropped the connection when it revoked us.
        withTimeout(30_000) { transport.connectedDeviceIds.first { macId !in it } }
        log("connection to the Mac is gone")

        // We still have the Mac in our table (a revoked device is not told), so we will dial it; the Mac must refuse.
        transport.connect(host, port, macKey, macId)
        delay(8_000)
        assertFalse("the Mac must not keep a connection with a device it revoked", macId in transport.connectedDeviceIds.value)
        log("the Mac refused us after revoking")
        transport.shutdown()
    }
}
