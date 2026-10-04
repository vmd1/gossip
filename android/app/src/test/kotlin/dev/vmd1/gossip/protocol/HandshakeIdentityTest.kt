package dev.vmd1.gossip.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

class HandshakeIdentityTest {
    private val key = Base64.getEncoder().encodeToString(ByteArray(32) { it.toByte() })
    private val id = "11111111-1111-1111-1111-111111111111"

    @Test
    fun `round trips with and without a pairing token`() {
        val with = HandshakeIdentity(id, "Pixel", "android-phone", key, "tok")
        assertEquals(with, HandshakeIdentity.decode(with.encode()))
        assertNull(HandshakeIdentity.decode(HandshakeIdentity(id, "Pixel", "android-phone", key).encode()).pairingToken)
    }

    @Test
    fun `rejects a malformed device id or signing key`() {
        assertThrows(Exception::class.java) { HandshakeIdentity.decode(HandshakeIdentity("nope", "p", "mac", key).encode()) }
        assertThrows(Exception::class.java) { HandshakeIdentity.decode(HandshakeIdentity(id, "p", "mac", "AAAA").encode()) }
    }

    @Test
    fun `pairing code matches the Mac vector and ignores order`() {
        val a = ByteArray(32) { it.toByte() }
        val b = ByteArray(32) { (it + 32).toByte() }
        assertEquals("977 657", PairingCode.make(a, b))
        assertEquals("977 657", PairingCode.make(b, a))
    }

    @Test
    fun `token comparison needs both sides and an exact match`() {
        assertTrue(PairingCode.tokenMatches("abc", "abc"))
        assertFalse(PairingCode.tokenMatches("abc", "abd"))
        assertFalse(PairingCode.tokenMatches("abc", "ab"))
        assertFalse(PairingCode.tokenMatches(null, "abc"))
        assertFalse(PairingCode.tokenMatches("abc", null))
    }
}
