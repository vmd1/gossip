package dev.vmd1.gossip.transport

import dev.vmd1.gossip.transport.RelayEndpointPolicy.Failure
import dev.vmd1.gossip.transport.RelayEndpointPolicy.Result
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RelayEndpointPolicyTest {
    private fun origin(text: String, loopback: Boolean = false): Any = RelayEndpointPolicy.normalizeOrigin(text, loopback).let { if (it is Result.Ok) it.origin else (it as Result.Error).failure }

    @Test
    fun theShippedPlaceholderIsNotConfiguredAndResolvesToNothing() {
        assertFalse(RelayEndpointPolicy.isDefaultConfigured)
        assertNull("no origin, so no socket is ever attempted", RelayEndpointPolicy.resolveOrigin("", allowInsecureLoopback = false))
        assertNull(RelayEndpointPolicy.resolveOrigin("   ", allowInsecureLoopback = true))
    }

    @Test
    fun normalizesWssAddresses() {
        assertEquals("wss://relay.example.com", origin("wss://relay.example.com"))
        assertEquals("wss://relay.example.com", origin("  WSS://Relay.Example.com/  "))
        assertEquals("wss://relay.example.com:8443", origin("wss://relay.example.com:8443/connect"))
    }

    @Test
    fun rejectsEverythingButBareWssOrigins() {
        assertEquals(Failure.MALFORMED, origin(""))
        assertEquals(Failure.MALFORMED, origin("not a url"))
        assertEquals(Failure.INSECURE_SCHEME, origin("https://relay.example.com"))
        assertEquals(Failure.INSECURE_SCHEME, origin("ws://relay.example.com"))
        assertEquals(Failure.INSECURE_SCHEME, origin("ws://relay.example.com", loopback = true))
        assertEquals(Failure.CREDENTIALS_NOT_ALLOWED, origin("wss://user:pw@relay.example.com"))
        assertEquals(Failure.UNEXPECTED_COMPONENTS, origin("wss://relay.example.com/other"))
        assertEquals(Failure.UNEXPECTED_COMPONENTS, origin("wss://relay.example.com/?token=1"))
        assertEquals(Failure.UNEXPECTED_COMPONENTS, origin("wss://relay.example.com/#frag"))
        assertEquals(Failure.MALFORMED, origin("wss://relay.example.com:99999"))
    }

    @Test
    fun plainWsIsOnlyForLoopbackAndOnlyWhenAllowed() {
        assertEquals(Failure.INSECURE_SCHEME, origin("ws://127.0.0.1:8099"))
        assertEquals("ws://127.0.0.1:8099", origin("ws://127.0.0.1:8099", loopback = true))
        assertEquals("ws://localhost:8099", origin("ws://localhost:8099", loopback = true))
        assertEquals("ws://10.0.2.2:8099", origin("ws://10.0.2.2:8099", loopback = true))
        assertEquals("ws://[::1]:8099", origin("ws://[::1]:8099", loopback = true))
        assertEquals(Failure.INSECURE_SCHEME, origin("ws://192.168.1.5:8099", loopback = true))
    }

    @Test
    fun aCustomAddressReplacesTheDefaultAndReportsItsOwnErrors() {
        assertEquals(Result.Ok("wss://my.relay.test"), RelayEndpointPolicy.resolveOrigin("wss://my.relay.test", allowInsecureLoopback = false))
        assertEquals(Result.Error(Failure.INSECURE_SCHEME), RelayEndpointPolicy.resolveOrigin("ws://my.relay.test", allowInsecureLoopback = false))
    }

    @Test
    fun connectUrlsMustBeWssToTheConfiguredHost() {
        val custom = "wss://my.relay.test"
        assertEquals("wss://my.relay.test/connect", RelayEndpointPolicy.validateConnectUrl("wss://my.relay.test/connect", custom, false))
        assertNull("another host", RelayEndpointPolicy.validateConnectUrl("wss://evil.test/connect", custom, false))
        assertNull("not allowlisted without a custom address", RelayEndpointPolicy.validateConnectUrl("wss://my.relay.test/connect", "", false))
        assertNull("the unconfigured placeholder host is never allowed", RelayEndpointPolicy.validateConnectUrl("wss://relay.gossip.invalid/connect", "", false))
        assertNull("credentials", RelayEndpointPolicy.validateConnectUrl("wss://u:p@my.relay.test/connect", custom, false))
        assertNull("other schemes", RelayEndpointPolicy.validateConnectUrl("https://my.relay.test/connect", custom, false))
        assertNull("garbage", RelayEndpointPolicy.validateConnectUrl("::::", custom, false))
    }

    @Test
    fun cleartextConnectUrlsAreLoopbackOnlyAndDebugOnly() {
        assertEquals("ws://127.0.0.1:8099/connect", RelayEndpointPolicy.validateConnectUrl("ws://127.0.0.1:8099/connect", "", true))
        assertEquals("ws://10.0.2.2:8099/connect", RelayEndpointPolicy.validateConnectUrl("ws://10.0.2.2:8099/connect", "", true))
        assertNull("release builds never allow ws://", RelayEndpointPolicy.validateConnectUrl("ws://127.0.0.1:8099/connect", "", false))
        assertNull("not loopback", RelayEndpointPolicy.validateConnectUrl("ws://example.com/connect", "", true))
        // Even a custom wss address does not unlock cleartext to its host.
        assertNull(RelayEndpointPolicy.validateConnectUrl("ws://my.relay.test/connect", "wss://my.relay.test", true))
    }

    @Test
    fun theLogLineNeverContainsMoreThanTheHost() {
        assertEquals("my.relay.test", RelayEndpointPolicy.loggable("wss://my.relay.test:8443/connect?t=secret"))
        assertEquals("relay", RelayEndpointPolicy.loggable("::::"))
    }

    @Test
    fun releaseDefaultsAreStrictInThisBuildType() {
        // The unit tests run the debug variant; the point is that the flag follows BuildConfig and is a plain boolean.
        assertEquals(dev.vmd1.gossip.BuildConfig.DEBUG, RelayEndpointPolicy.allowsInsecureLoopback)
        assertTrue(RelayEndpointPolicy.isLoopback("localhost"))
    }
}
