package dev.vmd1.gossip.protocol

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject

/**
 * The payload carried inside a `handshake.hello` / `handshake.ack` envelope: the raw
 * Noise_IK handshake message (base64) for this step, plus this device's display name
 * and type. Envelopes of these two types are the one exception to "payload is
 * Noise-encrypted ciphertext" — they're sent as plaintext-framed JSON, since no Noise
 * transport key exists yet; every envelope after the handshake completes is encrypted.
 *
 * [signingPublicKey] is this device's Ed25519 *signing* public key (base64, raw 32
 * bytes) — distinct from [noise]'s X25519 key-agreement key. Carried here so the
 * receiver can populate `TrustedDevice.signingPublicKey` the moment a device is
 * paired/reconnected, since neither side otherwise has anywhere to learn a peer's
 * signing key (see `docs/ble-hotspot-protocol.md`'s "GATT request authentication"
 * design point — signed hotspot requests depend on this being populated).
 */
@Serializable
data class HandshakePayload(
    val noise: String
) {
    fun toJsonObject(): JsonObject = Envelope.json.encodeToJsonElement(serializer(), this) as JsonObject

    companion object {
        fun fromJsonObject(obj: JsonObject): HandshakePayload = Envelope.json.decodeFromJsonElement(serializer(), obj)
    }
}

/**
 * Who a peer says it is, carried inside the Noise handshake payload (message 1 from the
 * initiator, message 2 from the responder) so it is encrypted and bound to the
 * handshake instead of riding in the plaintext `handshake.*` envelope. Mac has the same
 * shape (`HandshakeIdentity.swift`).
 */
@Serializable
data class HandshakeIdentity(
    val deviceId: String,
    val deviceName: String,
    val deviceType: String,
    /** Base64 raw Ed25519 public key. */
    val signingPublicKey: String,
    /** Only sent by a device that scanned a pairing QR; proves it saw that code. */
    val pairingToken: String? = null
) {
    fun encode(): ByteArray = Envelope.json.encodeToString(serializer(), this).toByteArray(Charsets.UTF_8)

    companion object {
        fun decode(bytes: ByteArray): HandshakeIdentity {
            val decoded = Envelope.json.decodeFromString(serializer(), String(bytes, Charsets.UTF_8))
            java.util.UUID.fromString(decoded.deviceId)
            require(java.util.Base64.getDecoder().decode(decoded.signingPublicKey).size == 32) { "bad signing key" }
            return decoded
        }
    }
}

object PairingCode {
    /** A short code both devices derive from the two Noise static keys, shown on both
     *  screens during pairing. Order-independent; Mac has the same function. */
    fun make(a: ByteArray, b: ByteArray): String {
        val (lo, hi) = if (compare(a, b) <= 0) a to b else b to a
        val digest = java.security.MessageDigest.getInstance("SHA-256")
            .digest("gossip-pairing-code-v1".toByteArray(Charsets.UTF_8) + lo + hi)
        var value = 0L
        for (i in 0 until 4) value = (value shl 8) or (digest[i].toLong() and 0xff)
        val s = "%06d".format(value % 1_000_000)
        return "${s.substring(0, 3)} ${s.substring(3)}"
    }

    /** Whether what the user typed is the displayed code (spaces and other separators ignored). */
    fun entryMatches(entry: String, expected: String): Boolean {
        val typed = entry.filter { it.isDigit() }
        val want = expected.filter { it.isDigit() }
        return want.length == 6 && typed == want
    }

    /** Constant-time token comparison; null on either side never matches. */
    fun tokenMatches(armed: String?, presented: String?): Boolean {
        if (armed == null || presented == null) return false
        return java.security.MessageDigest.isEqual(armed.toByteArray(Charsets.UTF_8), presented.toByteArray(Charsets.UTF_8))
    }

    private fun compare(a: ByteArray, b: ByteArray): Int {
        for (i in 0 until minOf(a.size, b.size)) {
            val d = (a[i].toInt() and 0xff) - (b[i].toInt() and 0xff)
            if (d != 0) return d
        }
        return a.size - b.size
    }
}
