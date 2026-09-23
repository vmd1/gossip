package com.connect.crypto

import java.security.GeneralSecurityException
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

private const val PROTOCOL_NAME = "Noise_IK_25519_ChaChaPoly_SHA256"
private const val DH_LEN = 32
private const val TAG_LEN = 16

enum class NoiseRole { INITIATOR, RESPONDER }

class NoiseHandshakeException(message: String, cause: Throwable? = null) : Exception(message, cause)

/** Result of processing the initiator's first handshake message. */
data class NoiseHandshakeResult(val payload: ByteArray, val remoteStaticPublicKey: ByteArray)

/**
 * A from-scratch implementation of the Noise_IK_25519_ChaChaPoly_SHA256 handshake
 * (Noise Protocol Framework, pattern IK: `e -> es, s, ss` / `e, ee, se`) plus the
 * derived post-handshake transport cipher that encrypts every framed envelope.
 *
 * The QR code scanned during pairing carries the Mac's static public key
 * out-of-band, which is what makes IK usable on the very first connection (not
 * just on reconnects) — the initiator (this device, when it scans) already
 * knows the responder's static key before message 1 is sent.
 *
 * Tink does not cleanly expose the low-level X25519/HKDF primitives a hand-rolled
 * Noise state machine needs, so DH agreement here uses BouncyCastle and the
 * AEAD/hash steps use the platform javax.crypto / java.security providers
 * (Conscrypt on Android has supported ChaCha20-Poly1305 since API 28, below our
 * minSdk 29 floor).
 */
class NoiseSession(
    private val role: NoiseRole,
    private val staticKeyPair: X25519KeyPair,
    remoteStaticPublicKey: ByteArray? = null
) {
    private var h: ByteArray
    private var ck: ByteArray
    private var k: ByteArray? = null
    private var n: Long = 0

    private var localEphemeral: X25519KeyPair? = null
    private var remoteEphemeralPublic: ByteArray? = null
    private var remoteStatic: ByteArray? = remoteStaticPublicKey

    var isComplete: Boolean = false
        private set

    private var sendCipher: CipherState? = null
    private var receiveCipher: CipherState? = null

    init {
        // Noise spec ("Protocol names", section 3): if protocol_name is <= HASHLEN
        // (32 for SHA256) bytes, h is set to protocol_name zero-padded to HASHLEN
        // bytes -- NOT hashed. Only names longer than HASHLEN get SHA256'd. Our
        // protocol name is exactly 32 bytes, so this must be used verbatim
        // (zero-padded, here a no-op since it's already 32 bytes); hashing it
        // unconditionally (the previous bug here) silently diverged the entire
        // transcript hash chain from the Mac side, which implements this correctly.
        val nameBytes = PROTOCOL_NAME.toByteArray(Charsets.US_ASCII)
        val initialH = if (nameBytes.size <= 32) {
            nameBytes + ByteArray(32 - nameBytes.size)
        } else {
            sha256(nameBytes)
        }
        h = initialH
        ck = initialH
        mixHash(ByteArray(0)) // empty prologue

        when (role) {
            NoiseRole.INITIATOR -> {
                requireNotNull(remoteStaticPublicKey) {
                    "Initiator requires the responder's static public key, learned out-of-band from the QR code"
                }
                mixHash(remoteStaticPublicKey)
            }
            NoiseRole.RESPONDER -> {
                mixHash(staticKeyPair.publicKey)
            }
        }
    }

    /** Initiator: build message 1 (`e, es, s, ss`) carrying [payload] (handshake.hello info). */
    fun writeMessage1(payload: ByteArray): ByteArray {
        check(role == NoiseRole.INITIATOR) { "Only the initiator sends message 1" }
        val rs = remoteStatic ?: throw NoiseHandshakeException("Missing responder static key")

        val e = X25519Utils.generateKeyPair()
        localEphemeral = e
        mixHash(e.publicKey)

        val es = X25519Utils.dh(e.privateKey, rs)
        mixKey(es)

        val encryptedStatic = encryptAndHash(staticKeyPair.publicKey)

        val ss = X25519Utils.dh(staticKeyPair.privateKey, rs)
        mixKey(ss)

        val encryptedPayload = encryptAndHash(payload)

        return e.publicKey + encryptedStatic + encryptedPayload
    }

    /** Responder: consume message 1, returning the decrypted payload and the initiator's static key. */
    fun readMessage1(message: ByteArray): NoiseHandshakeResult {
        check(role == NoiseRole.RESPONDER) { "Only the responder reads message 1" }
        if (message.size < DH_LEN + (DH_LEN + TAG_LEN)) {
            throw NoiseHandshakeException("Handshake message 1 too short")
        }
        var offset = 0
        val re = message.copyOfRange(offset, offset + DH_LEN); offset += DH_LEN
        remoteEphemeralPublic = re
        mixHash(re)

        val es = X25519Utils.dh(staticKeyPair.privateKey, re)
        mixKey(es)

        val encryptedStaticLen = DH_LEN + TAG_LEN
        val encryptedStatic = message.copyOfRange(offset, offset + encryptedStaticLen); offset += encryptedStaticLen
        val rs = decryptAndHash(encryptedStatic)
        remoteStatic = rs

        val ss = X25519Utils.dh(staticKeyPair.privateKey, rs)
        mixKey(ss)

        val encryptedPayload = message.copyOfRange(offset, message.size)
        val payload = decryptAndHash(encryptedPayload)

        return NoiseHandshakeResult(payload, rs)
    }

    /** Responder: build message 2 (`e, ee, se`), completing the handshake on this side. */
    fun writeMessage2(payload: ByteArray): ByteArray {
        check(role == NoiseRole.RESPONDER) { "Only the responder sends message 2" }
        val re = remoteEphemeralPublic ?: throw NoiseHandshakeException("Message 1 not yet processed")
        val rs = remoteStatic ?: throw NoiseHandshakeException("Message 1 not yet processed")

        val e = X25519Utils.generateKeyPair()
        localEphemeral = e
        mixHash(e.publicKey)

        val ee = X25519Utils.dh(e.privateKey, re)
        mixKey(ee)

        val se = X25519Utils.dh(e.privateKey, rs)
        mixKey(se)

        val encryptedPayload = encryptAndHash(payload)
        finishHandshake()
        return e.publicKey + encryptedPayload
    }

    /** Initiator: consume message 2, completing the handshake on this side. */
    fun readMessage2(message: ByteArray): ByteArray {
        check(role == NoiseRole.INITIATOR) { "Only the initiator reads message 2" }
        val localE = localEphemeral ?: throw NoiseHandshakeException("Message 1 not yet sent")
        val rs = remoteStatic ?: throw NoiseHandshakeException("Missing responder static key")
        if (message.size < DH_LEN + TAG_LEN) {
            throw NoiseHandshakeException("Handshake message 2 too short")
        }

        var offset = 0
        val re = message.copyOfRange(offset, offset + DH_LEN); offset += DH_LEN
        remoteEphemeralPublic = re
        mixHash(re)

        val ee = X25519Utils.dh(localE.privateKey, re)
        mixKey(ee)

        val se = X25519Utils.dh(staticKeyPair.privateKey, re)
        mixKey(se)

        val encryptedPayload = message.copyOfRange(offset, message.size)
        val payload = decryptAndHash(encryptedPayload)
        finishHandshake()
        return payload
    }

    /** Post-handshake: encrypt a plaintext framed envelope for the wire. */
    fun encryptTransportMessage(plaintext: ByteArray): ByteArray {
        val cipher = sendCipher ?: throw NoiseHandshakeException("Handshake not complete")
        return cipher.encryptWithAd(ByteArray(0), plaintext)
    }

    /** Post-handshake: decrypt a ciphertext received off the wire back into an envelope. */
    fun decryptTransportMessage(ciphertext: ByteArray): ByteArray {
        val cipher = receiveCipher ?: throw NoiseHandshakeException("Handshake not complete")
        return cipher.decryptWithAd(ByteArray(0), ciphertext)
    }

    val remoteStaticKey: ByteArray?
        get() = remoteStatic

    private fun finishHandshake() {
        val (k1, k2) = hkdf2(ck, ByteArray(0))
        if (role == NoiseRole.INITIATOR) {
            sendCipher = CipherState(k1)
            receiveCipher = CipherState(k2)
        } else {
            sendCipher = CipherState(k2)
            receiveCipher = CipherState(k1)
        }
        isComplete = true
    }

    private fun mixHash(data: ByteArray) {
        h = sha256(h + data)
    }

    private fun mixKey(inputKeyMaterial: ByteArray) {
        val (newCk, tempK) = hkdf2(ck, inputKeyMaterial)
        ck = newCk
        k = tempK
        n = 0
    }

    private fun encryptAndHash(plaintext: ByteArray): ByteArray {
        val currentK = k
        val ciphertext = if (currentK == null) {
            plaintext
        } else {
            val ct = chachaPolyEncrypt(currentK, nonceBytes(n), h, plaintext)
            n++
            ct
        }
        mixHash(ciphertext)
        return ciphertext
    }

    private fun decryptAndHash(ciphertext: ByteArray): ByteArray {
        val currentK = k
        val plaintext = if (currentK == null) {
            ciphertext
        } else {
            val pt = chachaPolyDecrypt(currentK, nonceBytes(n), h, ciphertext)
            n++
            pt
        }
        mixHash(ciphertext)
        return plaintext
    }
}

/** Post-handshake one-way transport cipher (one per direction) derived by `Split()`. */
private class CipherState(private val key: ByteArray) {
    private var n: Long = 0

    fun encryptWithAd(ad: ByteArray, plaintext: ByteArray): ByteArray {
        val ct = chachaPolyEncrypt(key, nonceBytes(n), ad, plaintext)
        n++
        return ct
    }

    fun decryptWithAd(ad: ByteArray, ciphertext: ByteArray): ByteArray {
        val pt = chachaPolyDecrypt(key, nonceBytes(n), ad, ciphertext)
        n++
        return pt
    }
}

private fun nonceBytes(counter: Long): ByteArray {
    // Noise nonce format for ChaChaPoly: 4 zero bytes followed by 8 little-endian counter bytes.
    val buf = ByteArray(12)
    for (i in 0 until 8) {
        buf[4 + i] = ((counter shr (8 * i)) and 0xFF).toByte()
    }
    return buf
}

private fun chachaPolyEncrypt(key: ByteArray, nonce: ByteArray, ad: ByteArray, plaintext: ByteArray): ByteArray {
    try {
        val cipher = Cipher.getInstance("ChaCha20-Poly1305")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "ChaCha20"), IvParameterSpec(nonce))
        if (ad.isNotEmpty()) cipher.updateAAD(ad)
        return cipher.doFinal(plaintext)
    } catch (e: GeneralSecurityException) {
        throw NoiseHandshakeException("AEAD encryption failed", e)
    }
}

private fun chachaPolyDecrypt(key: ByteArray, nonce: ByteArray, ad: ByteArray, ciphertext: ByteArray): ByteArray {
    try {
        val cipher = Cipher.getInstance("ChaCha20-Poly1305")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "ChaCha20"), IvParameterSpec(nonce))
        if (ad.isNotEmpty()) cipher.updateAAD(ad)
        return cipher.doFinal(ciphertext)
    } catch (e: GeneralSecurityException) {
        throw NoiseHandshakeException("AEAD decryption failed (wrong key or tampered data)", e)
    }
}

private fun hkdf2(chainingKey: ByteArray, inputKeyMaterial: ByteArray): Pair<ByteArray, ByteArray> {
    val tempKey = hmacSha256(chainingKey, inputKeyMaterial)
    val output1 = hmacSha256(tempKey, byteArrayOf(0x01))
    val output2 = hmacSha256(tempKey, output1 + byteArrayOf(0x02))
    return Pair(output1, output2)
}

private fun hmacSha256(key: ByteArray, data: ByteArray): ByteArray {
    val mac = Mac.getInstance("HmacSHA256")
    mac.init(SecretKeySpec(key, "HmacSHA256"))
    return mac.doFinal(data)
}

private fun sha256(data: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(data)
