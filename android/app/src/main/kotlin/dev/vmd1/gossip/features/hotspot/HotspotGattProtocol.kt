package dev.vmd1.gossip.features.hotspot

import dev.vmd1.gossip.crypto.X25519Utils
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters
import org.bouncycastle.crypto.signers.Ed25519Signer
import java.util.UUID
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Wire-level contract for Instant Hotspot's BLE GATT control channel — see
 * `docs/ble-hotspot-protocol.md`. This travels over a raw GATT service, not the
 * Noise-encrypted Wi-Fi mesh transport (`schema/message-types.md`/`Envelope`), since the
 * whole point of Instant Hotspot is reaching a device with no IP connectivity at all,
 * which rules out the mesh transport by definition. Kotlin and Swift each implement this
 * independently, same as every other wire-level contract in this project — this file (and
 * its Mac counterpart, `HotspotGattProtocol.swift`) is the source of truth both must agree
 * on byte-for-byte.
 */
object HotspotGattProtocol {
    /** Custom 128-bit UUIDs — this is a personal project, not requiring SIG registration,
     *  same rationale as the `0xFFFF` "for testing" manufacturer ID used for BLE proximity
     *  advertising (`docs/ble-proximity-protocol.md`). */
    val SERVICE_UUID: UUID = UUID.fromString("8f9a1000-1a2b-4c3d-9e0f-1234567890ab")
    val REQUEST_CHARACTERISTIC_UUID: UUID = UUID.fromString("8f9a1001-1a2b-4c3d-9e0f-1234567890ab")
    val RESPONSE_CHARACTERISTIC_UUID: UUID = UUID.fromString("8f9a1002-1a2b-4c3d-9e0f-1234567890ab")
    /** Client Characteristic Configuration Descriptor — standard Bluetooth base UUID,
     *  needed to enable notifications on [RESPONSE_CHARACTERISTIC_UUID]. */
    val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    /** Payload bytes per GATT write/notify chunk, deliberately conservative: 1 (flag byte)
     *  + 19 = 20 bytes, which fits inside the *default*, un-negotiated 23-byte ATT MTU (20
     *  usable bytes after the 3-byte ATT header) on every BLE stack — this channel never
     *  depends on MTU negotiation succeeding, trading a few extra round-trips for a
     *  chunking scheme that just always works. See [ChunkReassembler] for reassembly. */
    const val CHUNK_PAYLOAD_SIZE = 19
    private const val FLAG_LAST_CHUNK: Byte = 0x01

    fun encodeChunks(message: ByteArray): List<ByteArray> {
        if (message.isEmpty()) return listOf(byteArrayOf(FLAG_LAST_CHUNK))
        val chunks = mutableListOf<ByteArray>()
        var offset = 0
        while (offset < message.size) {
            val end = minOf(offset + CHUNK_PAYLOAD_SIZE, message.size)
            val isLast = end == message.size
            val chunk = ByteArray((end - offset) + 1)
            chunk[0] = if (isLast) FLAG_LAST_CHUNK else 0
            System.arraycopy(message, offset, chunk, 1, end - offset)
            chunks.add(chunk)
            offset = end
        }
        return chunks
    }

    /** Reassembles chunks written/notified one at a time (possibly across multiple GATT
     *  operations) back into the original message. Not thread-safe — callers own
     *  serializing chunk delivery per connection, which every GATT callback API already
     *  guarantees (one callback thread per connection). */
    class ChunkReassembler {
        private val buffer = java.io.ByteArrayOutputStream()

        /** Feeds one chunk; returns the complete reassembled message once the last chunk
         *  arrives, or `null` if more chunks are still expected. Resets automatically after
         *  returning a complete message, so the same instance can be reused for the next
         *  request/response on the same connection. */
        fun feed(chunk: ByteArray): ByteArray? {
            if (chunk.isEmpty()) return null
            buffer.write(chunk, 1, chunk.size - 1)
            if ((chunk[0].toInt() and FLAG_LAST_CHUNK.toInt()) == 0) return null
            val result = buffer.toByteArray()
            buffer.reset()
            return result
        }
    }

    @Serializable
    data class ToggleRequestPayload(
        val id: String,
        val en: Boolean,
        val n: String,
        val s: String
    ) {
        companion object {
            /** Builds and signs a fresh request. [privateKeySeed] is the requester's raw
             *  32-byte Ed25519 private key seed (`IdentityKeyStore.ed25519PrivateKey`). */
            fun create(requesterId: String, enable: Boolean, privateKeySeed: ByteArray): ToggleRequestPayload {
                val nonce = UUID.randomUUID().toString()
                val signature = sign(privateKeySeed, signedString(requesterId, enable, nonce))
                return ToggleRequestPayload(id = requesterId, en = enable, n = nonce, s = signature)
            }
        }

        fun isSignatureValid(signingPublicKey: ByteArray): Boolean =
            verify(signingPublicKey, signedString(id, en, n), s)
    }

    @Serializable
    private data class CredentialPlaintext(val ssid: String, val pass: String)

    /** [cred], when present, is base64(12-byte AES-GCM nonce || ciphertext+tag) encrypting
     *  a compact JSON `{"ssid":...,"pass":...}` — see [encryptCredentials]/
     *  [decryptCredentials]. Signed over the *ciphertext* (not plaintext credentials), so
     *  the signature also protects the ciphertext's integrity end to end, on top of
     *  AES-GCM's own built-in tag. */
    @Serializable
    data class StatusPayload(
        val id: String,
        val ok: Boolean,
        val n: String,
        val s: String,
        val cred: String? = null
    ) {
        companion object {
            fun create(
                providerId: String,
                enabled: Boolean,
                nonce: String,
                privateKeySeed: ByteArray,
                sharedSecretKey: ByteArray? = null,
                ssid: String? = null,
                passphrase: String? = null
            ): StatusPayload {
                val cred = if (ssid != null && passphrase != null && sharedSecretKey != null) {
                    encryptCredentials(sharedSecretKey, ssid, passphrase)
                } else {
                    null
                }
                val signature = sign(privateKeySeed, signedString(providerId, enabled, cred, nonce))
                return StatusPayload(id = providerId, ok = enabled, n = nonce, s = signature, cred = cred)
            }
        }

        fun isSignatureValid(signingPublicKey: ByteArray): Boolean =
            verify(signingPublicKey, signedString(id, ok, cred, n), s)

        /** Decrypts [cred] using the shared secret derived between this device and the
         *  provider (see [deriveSharedSecretKey]). Returns `null` if there was no
         *  credential blob, the caller hasn't verified [isSignatureValid] first (callers
         *  must check that separately — this method doesn't re-check it), or decryption
         *  fails (wrong key, corrupted/tampered ciphertext — AES-GCM's tag catches this). */
        fun decryptCredentials(sharedSecretKey: ByteArray): Pair<String, String>? {
            val blob = cred ?: return null
            return HotspotGattProtocol.decryptCredentials(sharedSecretKey, blob)
        }
    }

    private fun signedString(requesterId: String, enable: Boolean, nonce: String): String =
        "hotspot.toggle_request|$requesterId|$enable|$nonce"

    private fun signedString(providerId: String, enabled: Boolean, cred: String?, nonce: String): String =
        "hotspot.status|$providerId|$enabled|${cred.orEmpty()}|$nonce"

    /** Derives a symmetric key from this device's X25519 identity private key and the
     *  peer's X25519 identity public key (the same static keys `TrustedDevice.publicKey`
     *  already stores and Noise_IK already uses) via ECDH, then SHA-256 with a
     *  domain-separation label — **not** the raw ECDH output — so this key can never
     *  collide with (or weaken) the Noise_IK session key the same keypair also derives,
     *  even though both consume the same underlying X25519 agreement. Symmetric in the
     *  cryptographic sense: either side computes the same key regardless of who calls
     *  this with which (private, public) pair, since X25519 agreement itself is
     *  symmetric (dh(a_priv, b_pub) == dh(b_priv, a_pub)). */
    fun deriveSharedSecretKey(localX25519PrivateKey: ByteArray, remoteX25519PublicKey: ByteArray): ByteArray {
        val agreement = X25519Utils.dh(localX25519PrivateKey, remoteX25519PublicKey)
        val digest = java.security.MessageDigest.getInstance("SHA-256")
        digest.update(agreement)
        digest.update("connect-hotspot-gatt-v1".toByteArray(Charsets.UTF_8))
        return digest.digest()
    }

    private const val GCM_NONCE_SIZE = 12
    private const val GCM_TAG_BITS = 128

    private fun encryptCredentials(key: ByteArray, ssid: String, passphrase: String): String {
        val plaintext = json.encodeToString(CredentialPlaintext.serializer(), CredentialPlaintext(ssid, passphrase))
            .toByteArray(Charsets.UTF_8)
        val nonce = ByteArray(GCM_NONCE_SIZE).also { java.security.SecureRandom().nextBytes(it) }
        val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            javax.crypto.Cipher.ENCRYPT_MODE,
            javax.crypto.spec.SecretKeySpec(key, "AES"),
            javax.crypto.spec.GCMParameterSpec(GCM_TAG_BITS, nonce)
        )
        val ciphertext = cipher.doFinal(plaintext)
        return android.util.Base64.encodeToString(nonce + ciphertext, android.util.Base64.NO_WRAP)
    }

    private fun decryptCredentials(key: ByteArray, blob: String): Pair<String, String>? = runCatching {
        val raw = android.util.Base64.decode(blob, android.util.Base64.NO_WRAP)
        val nonce = raw.copyOfRange(0, GCM_NONCE_SIZE)
        val ciphertext = raw.copyOfRange(GCM_NONCE_SIZE, raw.size)
        val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            javax.crypto.Cipher.DECRYPT_MODE,
            javax.crypto.spec.SecretKeySpec(key, "AES"),
            javax.crypto.spec.GCMParameterSpec(GCM_TAG_BITS, nonce)
        )
        val plaintext = cipher.doFinal(ciphertext)
        val decoded = json.decodeFromString(CredentialPlaintext.serializer(), plaintext.toString(Charsets.UTF_8))
        decoded.ssid to decoded.pass
    }.getOrNull()

    private fun sign(privateKeySeed: ByteArray, message: String): String {
        val signer = Ed25519Signer()
        signer.init(true, Ed25519PrivateKeyParameters(privateKeySeed, 0))
        val messageBytes = message.toByteArray(Charsets.UTF_8)
        signer.update(messageBytes, 0, messageBytes.size)
        return android.util.Base64.encodeToString(signer.generateSignature(), android.util.Base64.NO_WRAP)
    }

    private fun verify(publicKey: ByteArray, message: String, signatureBase64: String): Boolean = runCatching {
        val signature = android.util.Base64.decode(signatureBase64, android.util.Base64.NO_WRAP)
        val verifier = Ed25519Signer()
        verifier.init(false, Ed25519PublicKeyParameters(publicKey, 0))
        val messageBytes = message.toByteArray(Charsets.UTF_8)
        verifier.update(messageBytes, 0, messageBytes.size)
        verifier.verifySignature(signature)
    }.getOrDefault(false)

    private val json = Json { ignoreUnknownKeys = true }

    fun encodeRequest(payload: ToggleRequestPayload): ByteArray =
        json.encodeToString(ToggleRequestPayload.serializer(), payload).toByteArray(Charsets.UTF_8)

    fun decodeRequest(bytes: ByteArray): ToggleRequestPayload? = runCatching {
        json.decodeFromString(ToggleRequestPayload.serializer(), bytes.toString(Charsets.UTF_8))
    }.getOrNull()

    fun encodeStatus(payload: StatusPayload): ByteArray =
        json.encodeToString(StatusPayload.serializer(), payload).toByteArray(Charsets.UTF_8)

    fun decodeStatus(bytes: ByteArray): StatusPayload? = runCatching {
        json.decodeFromString(StatusPayload.serializer(), bytes.toString(Charsets.UTF_8))
    }.getOrNull()
}
