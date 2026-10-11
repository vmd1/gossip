package dev.vmd1.gossip.transport

import dev.vmd1.gossip.features.trust.RosterGossipManager
import dev.vmd1.gossip.protocol.PairingCode
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.MessageDigest

class AuditHardeningTest {
    // Envelope shape checks, raw-frame hash binding, replay windows and the other wire-level hardening moved into the
    // Rust engine along with the code (see desktop/core/tests/engine.rs); the cases below are what stays in the app.

    @Test fun fingerprintAcceptsBothAdvertisementFormatsAndRejectsOthers() {
        val key = ByteArray(32) { it.toByte() }
        val digest = MessageDigest.getInstance("SHA-256").digest(key)
        val mac = java.util.Base64.getEncoder().encodeToString(digest.copyOf(8))
        val android = java.util.Base64.getEncoder().withoutPadding().encodeToString(digest).take(16)
        assertTrue(TransportManager.fingerprintMatches(mac, key))
        assertTrue(TransportManager.fingerprintMatches(android, key))
        assertFalse(TransportManager.fingerprintMatches("AAAAAAAAAAAA", key))
        assertFalse(TransportManager.fingerprintMatches(null, key))
    }

    @Test fun pairingCodeEntryNeedsTheExactSixDigits() {
        val code = PairingCode.make(ByteArray(32) { 1 }, ByteArray(32) { 2 })
        assertTrue(PairingCode.entryMatches(code, code))
        assertTrue(PairingCode.entryMatches(code.replace(" ", ""), code))
        assertFalse(PairingCode.entryMatches("", code))
        assertFalse(PairingCode.entryMatches("000000".takeIf { it != code.replace(" ", "") } ?: "111111", code))
    }

    @Test fun rosterValidationRejectsMalformedIdsAndKeys() {
        assertTrue(RosterGossipManager.isUuid(java.util.UUID.randomUUID().toString()))
        assertFalse(RosterGossipManager.isUuid("not-a-uuid"))
        assertFalse(RosterGossipManager.isUuid("1".repeat(64)))
        assertTrue(RosterGossipManager.decodeKey(java.util.Base64.getEncoder().encodeToString(ByteArray(32))) != null)
        assertEquals(null, RosterGossipManager.decodeKey(java.util.Base64.getEncoder().encodeToString(ByteArray(31))))
        assertEquals(null, RosterGossipManager.decodeKey("***not base64***"))
        assertNotEquals(null, JsonPrimitive("x"))
    }
}
