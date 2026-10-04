package dev.vmd1.gossip.protocol

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.Base64

/** The Kotlin side of the shared vector (`schema/envelope-signing-vectors.json`). */
class EnvelopeSigningTest {
    private fun vectors(): JsonObject {
        var dir: File? = File("").absoluteFile
        while (dir != null && !File(dir, "schema/envelope-signing-vectors.json").exists()) dir = dir.parentFile
        return Json.parseToJsonElement(File(checkNotNull(dir), "schema/envelope-signing-vectors.json").readText()).jsonObject
    }

    private fun keyPair(): Pair<ByteArray, ByteArray> {
        val priv = Ed25519PrivateKeyParameters(ByteArray(32) { (it * 7 + 3).toByte() }, 0)
        return priv.encoded to priv.generatePublicKey().encoded
    }

    @Test
    fun `canonical form and signature match the shared vector`() {
        val root = vectors()
        val envelope = Envelope.decode(root["envelope"]!!.toString().toByteArray())
        assertEquals(root["canonical"]!!.jsonPrimitive.content, String(EnvelopeSigning.signingBytes(envelope), Charsets.UTF_8))
        val publicKey = Base64.getDecoder().decode(root["signingPublicKey"]!!.jsonPrimitive.content)
        assertTrue(EnvelopeSigning.verify(envelope.copy(sig = root["signature"]!!.jsonPrimitive.content), publicKey))
    }

    @Test
    fun `tampering breaks the signature but relaying does not`() {
        val (priv, pub) = keyPair()
        val original = Envelope(
            type = "dnd.set", senderId = "11111111-1111-1111-1111-111111111111",
            recipientId = "22222222-2222-2222-2222-222222222222",
            payload = buildJsonObject { put("enabled", JsonPrimitive(true)) }
        )
        val signed = EnvelopeSigning.sign(original, priv)
        assertTrue(EnvelopeSigning.verify(signed, pub))
        assertTrue(EnvelopeSigning.verify(signed.copy(ttl = 3), pub))
        assertTrue(EnvelopeSigning.verify(Envelope.decode(signed.encode()), pub))

        assertFalse(EnvelopeSigning.verify(signed.copy(payload = buildJsonObject { put("enabled", JsonPrimitive(false)) }), pub))
        assertFalse(EnvelopeSigning.verify(signed.copy(recipientId = "33333333-3333-3333-3333-333333333333"), pub))
        assertFalse(EnvelopeSigning.verify(signed, Ed25519PrivateKeyParameters(ByteArray(32) { 9 }, 0).generatePublicKey().encoded))
        assertFalse(EnvelopeSigning.verify(original, pub))
    }

    @Test
    fun `fractional numbers cannot be signed`() {
        val e = Envelope(type = "battery.update", senderId = "11111111-1111-1111-1111-111111111111",
            payload = Json.parseToJsonElement("""{"level":0.5}""").jsonObject)
        assertThrows(IllegalArgumentException::class.java) { EnvelopeSigning.signingBytes(e) }
    }
}
