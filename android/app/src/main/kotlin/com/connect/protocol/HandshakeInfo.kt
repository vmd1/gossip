package com.connect.protocol

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject

/**
 * The payload carried inside a `handshake.hello` / `handshake.ack` envelope: the raw
 * Noise_IK handshake message (base64) for this step, plus this device's display name
 * and type. Envelopes of these two types are the one exception to "payload is
 * Noise-encrypted ciphertext" — they're sent as plaintext-framed JSON, since no Noise
 * transport key exists yet; every envelope after the handshake completes is encrypted.
 */
@Serializable
data class HandshakePayload(
    val noise: String,
    val deviceName: String,
    val deviceType: String
) {
    fun toJsonObject(): JsonObject = Envelope.json.encodeToJsonElement(serializer(), this) as JsonObject

    companion object {
        fun fromJsonObject(obj: JsonObject): HandshakePayload = Envelope.json.decodeFromJsonElement(serializer(), obj)
    }
}
