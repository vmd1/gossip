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
    val noise: String,
    val deviceName: String,
    val deviceType: String,
    val signingPublicKey: String
) {
    fun toJsonObject(): JsonObject = Envelope.json.encodeToJsonElement(serializer(), this) as JsonObject

    companion object {
        fun fromJsonObject(obj: JsonObject): HandshakePayload = Envelope.json.decodeFromJsonElement(serializer(), obj)
    }
}
