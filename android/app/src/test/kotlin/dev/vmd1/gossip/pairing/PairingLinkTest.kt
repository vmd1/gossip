package dev.vmd1.gossip.pairing

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingLinkTest {
    private val payload = PairingQrPayload(
        responderDeviceId = "B0FC8E8D-70F1-4983-90A7-7CF717296777",
        responderPublicKey = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",
        responderPublicKeyFingerprint = "fp",
        responderDeviceName = "Café “Mac” 日本",
        responderDeviceType = "mac",
        pairingToken = "token",
        responderSigningPublicKey = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
    )
    private val json = Json.encodeToString(PairingQrPayload.serializer(), payload)

    @Test
    fun roundTripsIncludingNonAscii() {
        val link = PairingLink.encode(json)
        assertTrue(link.startsWith("gossip-pair:"))
        assertTrue("typeable: no quotes, braces or padding", link.none { it in "{}\"=+/ " })
        assertEquals(json, PairingLink.decode(link))
    }

    @Test
    fun toleratesWhitespaceAddedByChatApps() {
        val link = PairingLink.encode(json)
        val wrapped = "  " + link.chunked(40).joinToString("\n") + "\n"
        assertEquals(json, PairingLink.decode(wrapped))
    }

    @Test
    fun acceptsTheRawQrJsonToo() {
        assertEquals(json, PairingLink.decode(json))
        assertEquals(json, PairingLink.decode("\n$json "))
    }

    @Test
    fun rejectsJunk() {
        assertNull(PairingLink.decode(""))
        assertNull(PairingLink.decode("hello"))
        assertNull(PairingLink.decode("gossip-pair:!!!not-base64!!!"))
    }
}
