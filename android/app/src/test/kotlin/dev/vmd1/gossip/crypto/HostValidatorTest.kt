package dev.vmd1.gossip.crypto

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HostValidatorTest {
    @Test
    fun `accepts addresses and hostnames`() {
        listOf("192.168.0.5", "100.64.1.2", "fe80::1", "fe80::1%en0", "2001:db8::ff00:42:8329", "tablet", "my-mac.tail1234.ts.net")
            .forEach { assertTrue(it, HostValidator.isValid(it)) }
    }

    @Test
    fun `rejects everything else`() {
        listOf("", " ", "256.1.1.1", "1.2.3", "host:7913", "http://x", "a b", "x/y", "-bad.example", "bad-.example", "a..b",
            "fe80::zz", "fe80::1%", "::1::2", "x".repeat(64) + ".com", "exa_mple.com", "例え.jp")
            .forEach { assertFalse(it, HostValidator.isValid(it)) }
    }

    @Test
    fun `the store refuses an invalid fallback host and keeps the old one`() {
        val store = TrustedDevicesStore(FakeSharedPreferences())
        store.addDevice(TrustedDevice("a", byteArrayOf(1), "d", dev.vmd1.gossip.protocol.DeviceType.MAC, 1L))
        assertTrue(store.setFallbackHost("a", "10.0.0.2"))
        assertFalse(store.setFallbackHost("a", "http://evil"))
        assertTrue(store.getDevice("a")!!.fallbackHost == "10.0.0.2")
        assertTrue(store.setFallbackHost("a", "  ")) // blank clears
        assertTrue(store.getDevice("a")!!.fallbackHost == null)
    }
}
