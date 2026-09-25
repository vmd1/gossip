package dev.vmd1.gossip.crypto

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertFalse
import org.junit.Test

class NoiseSessionTest {

    @Test
    fun `full IK handshake between two in-process instances completes and derives matching transport keys`() {
        val initiatorStatic = X25519Utils.generateKeyPair()
        val responderStatic = X25519Utils.generateKeyPair()

        val initiator = NoiseSession(NoiseRole.INITIATOR, initiatorStatic, responderStatic.publicKey)
        val responder = NoiseSession(NoiseRole.RESPONDER, responderStatic, null)

        val helloPayload = "hello-from-initiator".toByteArray()
        val message1 = initiator.writeMessage1(helloPayload)

        val result1 = responder.readMessage1(message1)
        assertArrayEquals(helloPayload, result1.payload)
        assertArrayEquals(initiatorStatic.publicKey, result1.remoteStaticPublicKey)

        val ackPayload = "hello-from-responder".toByteArray()
        val message2 = responder.writeMessage2(ackPayload)
        assertTrue(responder.isComplete)

        val decodedAck = initiator.readMessage2(message2)
        assertArrayEquals(ackPayload, decodedAck)
        assertTrue(initiator.isComplete)

        // Post-handshake transport encryption: initiator -> responder.
        val appMessage = "{\"type\":\"presence.online\"}".toByteArray()
        val ciphertext = initiator.encryptTransportMessage(appMessage)
        val plaintext = responder.decryptTransportMessage(ciphertext)
        assertArrayEquals(appMessage, plaintext)

        // And the other direction: responder -> initiator.
        val replyMessage = "{\"type\":\"presence.heartbeat\"}".toByteArray()
        val replyCiphertext = responder.encryptTransportMessage(replyMessage)
        val replyPlaintext = initiator.decryptTransportMessage(replyCiphertext)
        assertArrayEquals(replyMessage, replyPlaintext)
    }

    @Test(expected = NoiseHandshakeException::class)
    fun `decrypting a tampered ciphertext fails authentication`() {
        val initiatorStatic = X25519Utils.generateKeyPair()
        val responderStatic = X25519Utils.generateKeyPair()

        val initiator = NoiseSession(NoiseRole.INITIATOR, initiatorStatic, responderStatic.publicKey)
        val responder = NoiseSession(NoiseRole.RESPONDER, responderStatic, null)

        val message1 = initiator.writeMessage1(ByteArray(0))
        responder.readMessage1(message1)
        val message2 = responder.writeMessage2(ByteArray(0))
        initiator.readMessage2(message2)

        val ciphertext = initiator.encryptTransportMessage("secret".toByteArray())
        ciphertext[0] = (ciphertext[0].toInt() xor 0xFF).toByte() // flip every bit in the first byte
        responder.decryptTransportMessage(ciphertext)
    }

    @Test
    fun `handshake fails when initiator has the wrong responder static key`() {
        val initiatorStatic = X25519Utils.generateKeyPair()
        val responderStatic = X25519Utils.generateKeyPair()
        val wrongStatic = X25519Utils.generateKeyPair()

        val initiator = NoiseSession(NoiseRole.INITIATOR, initiatorStatic, wrongStatic.publicKey)
        val responder = NoiseSession(NoiseRole.RESPONDER, responderStatic, null)

        val message1 = initiator.writeMessage1(ByteArray(0))

        var threw = false
        try {
            responder.readMessage1(message1)
        } catch (e: NoiseHandshakeException) {
            threw = true
        }
        assertTrue("Handshake using the wrong static key should fail authentication", threw)
        assertFalse(responder.isComplete)
    }
}
