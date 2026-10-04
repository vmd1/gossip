package dev.vmd1.gossip.protocol

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters
import org.bouncycastle.crypto.signers.Ed25519Signer
import java.io.ByteArrayOutputStream
import java.util.Base64

/**
 * End-to-end authentication of an envelope's origin. Every envelope except the `handshake.*`
 * pair carries `sig`, an Ed25519 signature by `senderId`'s signing key over the envelope's
 * canonical form, so a relay (or anyone on the path) can't forge or re-target a message
 * "from" another device. `ttl` is excluded because every relaying hop decrements it. Mac has
 * the same canonicalisation (`EnvelopeSigning.swift`); both are checked against
 * `schema/envelope-signing-vectors.json`. See `docs/wire-protocol.md`.
 */
object EnvelopeSigning {
    private const val DOMAIN = "gossip-envelope-v1\n"
    private const val MAX_SAFE_INT = 9_007_199_254_740_992.0

    fun signingBytes(e: Envelope): ByteArray = DOMAIN.toByteArray(Charsets.UTF_8) + canonicalObject(e)

    fun canonicalObject(e: Envelope): ByteArray {
        val fields = mapOf<String, JsonElement>(
            "v" to JsonPrimitive(e.v),
            "id" to JsonPrimitive(e.id),
            "type" to JsonPrimitive(e.type),
            "senderId" to JsonPrimitive(e.senderId),
            "recipientId" to (e.recipientId?.let { JsonPrimitive(it) } ?: JsonNull),
            "broadcast" to JsonPrimitive(e.broadcast),
            "hasRawFollowup" to JsonPrimitive(e.hasRawFollowup),
            "ts" to JsonPrimitive(e.ts),
            "payload" to e.payload
        )
        val out = ByteArrayOutputStream()
        canonical(JsonObject(fields), out)
        return out.toByteArray()
    }

    /** Canonical JSON: object keys sorted by UTF-8 bytes, no whitespace, integers only
     *  (payloads never carry fractions), strings escape only `"`, `\` and control characters (`\b\t\n\f\r` short, others `\u00xx`). */
    private fun canonical(value: JsonElement, out: ByteArrayOutputStream) {
        when (value) {
            is JsonNull -> out.write("null".toByteArray())
            is JsonPrimitive -> when {
                value.isString -> writeString(value.content, out)
                value.content == "true" || value.content == "false" -> out.write(value.content.toByteArray())
                else -> {
                    val asLong = value.content.toLongOrNull()
                    val n = asLong?.toDouble() ?: value.content.toDoubleOrNull()
                    require(n != null && n == Math.rint(n) && Math.abs(n) < MAX_SAFE_INT) { "unsupported number ${value.content}" }
                    out.write((asLong ?: n!!.toLong()).toString().toByteArray())
                }
            }
            is JsonArray -> {
                out.write('['.code)
                value.forEachIndexed { i, item ->
                    if (i > 0) out.write(','.code)
                    canonical(item, out)
                }
                out.write(']'.code)
            }
            is JsonObject -> {
                out.write('{'.code)
                val keys = value.keys.sortedWith { a, b -> compareBytes(a.toByteArray(Charsets.UTF_8), b.toByteArray(Charsets.UTF_8)) }
                keys.forEachIndexed { i, key ->
                    if (i > 0) out.write(','.code)
                    writeString(key, out)
                    out.write(':'.code)
                    canonical(value.getValue(key), out)
                }
                out.write('}'.code)
            }
        }
    }

    private fun writeString(s: String, out: ByteArrayOutputStream) {
        out.write('"'.code)
        for (b in s.toByteArray(Charsets.UTF_8)) {
            val v = b.toInt() and 0xff
            when {
                v == '"'.code -> out.write("\\\"".toByteArray())
                v == '\\'.code -> out.write("\\\\".toByteArray())
                v == 0x08 -> out.write("\\b".toByteArray())
                v == 0x09 -> out.write("\\t".toByteArray())
                v == 0x0a -> out.write("\\n".toByteArray())
                v == 0x0c -> out.write("\\f".toByteArray())
                v == 0x0d -> out.write("\\r".toByteArray())
                v < 0x20 -> out.write("\\u%04x".format(v).toByteArray())
                else -> out.write(v)
            }
        }
        out.write('"'.code)
    }

    private fun compareBytes(a: ByteArray, b: ByteArray): Int {
        for (i in 0 until minOf(a.size, b.size)) {
            val d = (a[i].toInt() and 0xff) - (b[i].toInt() and 0xff)
            if (d != 0) return d
        }
        return a.size - b.size
    }

    fun sign(e: Envelope, privateKey: ByteArray): Envelope {
        val signer = Ed25519Signer()
        signer.init(true, Ed25519PrivateKeyParameters(privateKey, 0))
        val bytes = signingBytes(e)
        signer.update(bytes, 0, bytes.size)
        return e.copy(sig = Base64.getEncoder().encodeToString(signer.generateSignature()))
    }

    fun verify(e: Envelope, publicKey: ByteArray): Boolean = try {
        val sig = Base64.getDecoder().decode(e.sig ?: return false)
        val verifier = Ed25519Signer()
        verifier.init(false, Ed25519PublicKeyParameters(publicKey, 0))
        val bytes = signingBytes(e)
        verifier.update(bytes, 0, bytes.size)
        verifier.verifySignature(sig)
    } catch (_: Exception) {
        false
    }
}
