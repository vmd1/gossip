package dev.vmd1.gossip.e2e

import android.util.Log
import androidx.test.core.app.ApplicationProvider
import dev.vmd1.gossip.crypto.IdentityKeyStore
import dev.vmd1.gossip.crypto.TrustedDevicesStore
import dev.vmd1.gossip.protocol.DeviceType
import dev.vmd1.gossip.transport.MessageRouter
import dev.vmd1.gossip.transport.TransportManager
import dev.vmd1.gossip.transport.TransportManager.CodePairingEvent
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Android half of the code-pairing end-to-end test (`mac/GossipTests/EmulatorCodePairingE2ETests.swift`, run by
 * `scripts/e2e-code-pairing.sh`). This device plays the *new* device: it shows a pairing code, logs it as an `E2E:` line
 * for the Mac side to read, reports every attempt made against it, and checks that the Mac ends up trusted and connected
 * once the right code is typed there.
 */
class CodePairingE2eTest {
    private fun log(message: String) = Log.i("E2E", message)

    @Test
    fun showACodeAndWaitForTheMacToTypeIt() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        IdentityKeyStore.ensureInitialized(context)
        val identity = IdentityKeyStore.getInstance(context)
        val trusted = TrustedDevicesStore.getInstance(context)
        for (d in trusted.allDevices()) trusted.remove(d.deviceId)

        val transport = TransportManager(context, identity, trusted, MessageRouter(), deviceName = "E2E Emulator", deviceType = DeviceType.ANDROID_PHONE)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val paired = CompletableDeferred<String>()
        scope.launch {
            transport.codePairingEvents.collect { event ->
                when (event) {
                    is CodePairingEvent.WrongCode -> log("wrong attempts_left=${event.attemptsLeft}")
                    is CodePairingEvent.Succeeded -> { log("succeeded peer=${event.peer.deviceId}"); paired.complete(event.peer.deviceId) }
                    CodePairingEvent.TooManyAttempts -> log("too_many_attempts")
                    CodePairingEvent.Expired -> log("expired")
                    else -> log("event $event")
                }
            }
        }

        transport.listen(discover = false)
        val code = transport.startCodePairing()
        log("deviceId=${identity.deviceId}")
        log("code=$code")

        val macId = withTimeout(120_000) { paired.await() }
        assertTrue("the Mac is trusted after the code was accepted", trusted.isTrusted(macId))
        log("paired with $macId")

        // The Mac now connects the normal way (the Noise handshake, no prompt) because each side trusts the other.
        withTimeout(60_000) { transport.connectedDeviceIds.first { macId in it } }
        log("connected to $macId")
        // Stay up long enough for the Mac side to check its own view of the connection before this process ends.
        delay(20_000)
        transport.shutdown()
    }
}
