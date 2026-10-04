package dev.vmd1.gossip.features.screenmirror

import java.nio.ByteBuffer
import java.security.GeneralSecurityException
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Encrypts the screen-mirroring WebSocket (the Mac's `ScreenBridgeClient` is the other end). Same
 * construction as `ControlCipher` (HKDF-derived directional ChaCha20-Poly1305 keys, an 8-byte
 * counter nonce that must strictly increase, AAD binding direction and session id) under its own
 * labels, applied to arbitrary payloads. The per-session `secret` travels only in the
 * Noise-encrypted `screen.ready` message. Checked against `schema/screen-cipher-vectors.json`.
 * Thread-safe: [seal] and [open] synchronise on the instance.
 */
class ScreenCipher(secret: ByteArray, private val sessionId: String, private val deviceSide: Boolean = true) {
    class Failure(message: String) : Exception(message)

    private val sendDirection = if (deviceSide) DIR_D2V else DIR_V2D
    private val receiveDirection = if (deviceSide) DIR_V2D else DIR_D2V
    private val sendKey = SecretKeySpec(hkdf(secret, sessionId.toByteArray(), info(sendDirection)), "ChaCha20")
    private val receiveKey = SecretKeySpec(hkdf(secret, sessionId.toByteArray(), info(receiveDirection)), "ChaCha20")
    private var sendCounter = 0L
    private var lastReceived = 0L

    @Synchronized
    fun seal(plaintext: ByteArray): ByteArray {
        sendCounter += 1
        return seal(plaintext, sendCounter)
    }

    /** Exposed for the shared test vectors (fixed counter). */
    fun seal(plaintext: ByteArray, counter: Long): ByteArray {
        val c = newCipher()
        c.init(Cipher.ENCRYPT_MODE, sendKey, IvParameterSpec(nonce(counter)))
        c.updateAAD(aad(sendDirection))
        val sealed = c.doFinal(plaintext) // ciphertext || 16-byte tag
        return ByteBuffer.allocate(8 + sealed.size).putLong(counter).put(sealed).array()
    }

    /** Decrypts and authenticates [message]; throws [Failure] on a replay, a bad length or a forgery. */
    @Synchronized
    fun open(message: ByteArray): ByteArray {
        if (message.size < 8 + 16) throw Failure("bad length")
        val counter = ByteBuffer.wrap(message, 0, 8).long
        if (counter <= lastReceived) throw Failure("replayed")
        val plaintext = try {
            val c = newCipher()
            c.init(Cipher.DECRYPT_MODE, receiveKey, IvParameterSpec(nonce(counter)))
            c.updateAAD(aad(receiveDirection))
            c.doFinal(message, 8, message.size - 8)
        } catch (_: GeneralSecurityException) { throw Failure("authentication") }
        lastReceived = counter // only after authentication, so garbage can't burn counters
        return plaintext
    }

    private fun aad(direction: Int): ByteArray =
        LABEL.toByteArray() + byteArrayOf(direction.toByte()) + sessionId.toByteArray(Charsets.UTF_8)

    private fun nonce(counter: Long): ByteArray = ByteBuffer.allocate(12).putInt(0).putLong(counter).array()

    companion object {
        private const val LABEL = "gossip-screen-v1"
        const val DIR_V2D = 1
        const val DIR_D2V = 2
        private fun info(direction: Int) = "$LABEL ${if (direction == DIR_V2D) "v2d" else "d2v"}".toByteArray()

        /** HKDF-SHA256 (RFC 5869), one 32-byte output block. */
        internal fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray): ByteArray {
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(if (salt.isEmpty()) ByteArray(32) else salt, "HmacSHA256"))
            val prk = mac.doFinal(ikm)
            mac.init(SecretKeySpec(prk, "HmacSHA256"))
            mac.update(info); mac.update(1.toByte())
            return mac.doFinal()
        }
    }
}

private fun newCipher(): Cipher =
    try { Cipher.getInstance("ChaCha20-Poly1305") } catch (_: GeneralSecurityException) { Cipher.getInstance("ChaCha20/Poly1305/NoPadding") }
