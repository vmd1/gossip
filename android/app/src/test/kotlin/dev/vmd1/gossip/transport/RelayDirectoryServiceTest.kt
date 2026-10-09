package dev.vmd1.gossip.transport

import kotlinx.coroutines.Dispatchers
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import uniffi.gossip_ffi.RelayDirectoryScheduler
import java.io.File
import java.nio.file.Files

/**
 * The directory service with a fake HTTP layer and a controllable clock. The validation rules are covered by the Rust unit
 * tests; these cover the shell: caching, persistence across restarts, never overwriting a good cache with a bad answer,
 * and the changed origin the transport reconfigures on. Fetches run synchronously (an unconfined dispatcher).
 */
class RelayDirectoryServiceTest {
    private class FakeHttp : RelayDirectoryHttp {
        var response: ByteArray? = null
        var calls = 0
        override fun fetch(url: String): ByteArray? { calls++; return response }
    }

    private class Clock { var ms = 1_800_000_000_000L }

    private val endpoint = "https://gossip.vmd1.dev/relay.json"
    private lateinit var dir: File
    private lateinit var cacheFile: File

    @Before fun setUp() { dir = Files.createTempDirectory("relay-dir").toFile(); cacheFile = File(dir, "relay-directory.json") }
    @After fun tearDown() { dir.deleteRecursively() }

    private fun blob(server: String, extra: String = "") = """{"relayServer":"$server"$extra}""".toByteArray()

    private fun service(http: FakeHttp, clock: Clock, endpoint: String = this.endpoint) = RelayDirectoryService(
        endpoint = endpoint, http = http, cacheFile = cacheFile, allowInsecureLocal = false,
        scheduler = RelayDirectoryScheduler.withJitterPermille(0), now = { clock.ms }, fetchDispatcher = Dispatchers.Unconfined
    ).apply { wanted = true }

    @Test
    fun aValidFetchIsCachedAndApplied() {
        val http = FakeHttp().apply { response = blob("wss://eu.vmd1.dev", ""","unknown":[1]""") }
        val svc = service(http, Clock())
        assertTrue(svc.state.value.awaitingFirstAnswer)
        svc.tick()
        assertEquals("polls on launch", 1, http.calls)
        assertEquals("wss://eu.vmd1.dev", svc.state.value.cachedOrigin)
        assertTrue(svc.state.value.isFresh)
        assertFalse(svc.state.value.awaitingFirstAnswer)
        assertNotNull(svc.state.value.lastSuccessMs)
        val stored = Json.parseToJsonElement(cacheFile.readText()) as JsonObject
        assertEquals("the raw blob is kept exactly as received", String(http.response!!), (stored["raw"] as JsonPrimitive).content)
        assertNotNull(stored["fetchedAt"])
    }

    @Test
    fun anUnreachableDirectoryKeepsAndUsesTheCacheAcrossRestart() {
        val clock = Clock()
        service(FakeHttp().apply { response = blob("wss://eu.vmd1.dev") }, clock).tick()

        val down = FakeHttp()
        val second = service(down, clock)
        assertEquals("loaded from disk before any network", "wss://eu.vmd1.dev", second.state.value.cachedOrigin)
        assertFalse("from the cache, not refreshed: cached (offline)", second.state.value.isFresh)
        assertFalse(second.state.value.awaitingFirstAnswer)
        assertNotNull(second.state.value.lastSuccessMs)
        second.tick()
        assertEquals(1, down.calls)
        assertEquals("a failed fetch does not clear the cache", "wss://eu.vmd1.dev", second.state.value.cachedOrigin)
        assertFalse(second.state.value.isFresh)
        val s = second.state.value
        assertEquals(RelayEndpointPolicy.Source.CACHED_OFFLINE, RelayEndpointPolicy.resolve("", s.cachedOrigin, s.isFresh, false)?.source)
    }

    @Test
    fun invalidOrMaliciousFetchesNeverOverwriteTheCache() {
        val http = FakeHttp().apply { response = blob("wss://eu.vmd1.dev") }
        val clock = Clock()
        val svc = service(http, clock)
        svc.tick()
        val good = cacheFile.readText()
        val bad = listOf(
            blob("https://evil.com"), blob("evil.com"), blob(""), "not json".toByteArray(),
            "[]".toByteArray(), """{"relayServer":7}""".toByteArray(), byteArrayOf(-1, -2, 0),
            """{"relayServer":"wss://eu.vmd1.dev","pad":"${"a".repeat(20_000)}"}""".toByteArray()
        )
        for (body in bad) {
            http.response = body
            clock.ms += 7 * 3_600_000L
            svc.tick()
            assertEquals("wss://eu.vmd1.dev", svc.state.value.cachedOrigin)
            assertEquals("the file is untouched", good, cacheFile.readText())
            assertFalse(svc.state.value.isFresh)
            clock.ms += 31 * 60_000L
        }
        assertEquals(1 + bad.size, http.calls)
    }

    @Test
    fun anUnusableFirstFetchLeavesNoCacheAndTheDefaultApplies() {
        val http = FakeHttp().apply { response = blob("https://evil.example.com") }
        val svc = service(http, Clock())
        svc.tick()
        assertNull(svc.state.value.cachedOrigin)
        assertFalse(cacheFile.exists())
        assertFalse("the wait is over, the default applies", svc.state.value.awaitingFirstAnswer)
    }

    @Test
    fun aChangedRelayServerIsPickedUpAndReplacesTheCache() {
        val http = FakeHttp().apply { response = blob("wss://a.vmd1.dev") }
        val clock = Clock()
        val svc = service(http, clock)
        svc.tick()
        assertEquals("wss://a.vmd1.dev", svc.state.value.cachedOrigin)
        http.response = blob("wss://b.vmd1.dev")
        clock.ms += 7 * 3_600_000L
        svc.tick()
        assertEquals("wss://b.vmd1.dev", svc.state.value.cachedOrigin)
        assertEquals("wss://b.vmd1.dev", service(FakeHttp(), clock).state.value.cachedOrigin)
    }

    @Test
    fun pollingFollowsTheScheduleAndOnlyWhileWanted() {
        val http = FakeHttp().apply { response = blob("wss://a.vmd1.dev") }
        val clock = Clock()
        val svc = service(http, clock)
        svc.wanted = false
        svc.tick()
        assertEquals("relay off: no polling", 0, http.calls)
        svc.wanted = true
        svc.tick()
        assertEquals(1, http.calls)
        clock.ms += 3_600_000L
        svc.tick()
        assertEquals("not due yet", 1, http.calls)
        clock.ms += 6 * 3_600_000L
        svc.tick()
        assertEquals("due after six hours", 2, http.calls)
        svc.wanted = false
        clock.ms += 24 * 3_600_000L
        svc.tick()
        assertEquals(2, http.calls)
    }

    @Test
    fun failuresBackOffAndAConnectFailurePollIsRateLimited() {
        val http = FakeHttp()
        val clock = Clock()
        val svc = service(http, clock)
        svc.tick()
        assertEquals(1, http.calls)
        clock.ms += 30_000
        svc.tick()
        assertEquals("backoff is one minute", 1, http.calls)
        clock.ms += 31_000
        svc.tick()
        assertEquals(2, http.calls)
        svc.noteRelayConnectFailure()
        assertEquals("within ten minutes of the last attempt", 2, http.calls)
        clock.ms += 11 * 60_000L
        svc.noteRelayConnectFailure()
        assertEquals(3, http.calls)
    }

    @Test
    fun thePlaceholderEndpointNeverPolls() {
        val http = FakeHttp().apply { response = blob("wss://a.vmd1.dev") }
        val svc = service(http, Clock(), endpoint = "https://api.vmd1.dev/TODO-directory")
        assertFalse(svc.pollingEnabled)
        assertFalse("nothing to wait for", svc.state.value.awaitingFirstAnswer)
        svc.tick(); svc.noteRelayConnectFailure()
        assertEquals(0, http.calls)
        assertNull(svc.state.value.cachedOrigin)
    }

    @Test
    fun aCorruptCacheFileIsIgnoredAndRepairedByAGoodFetch() {
        for (junk in listOf("junk", """{"fetchedAt":1,"raw":"{\"relayServer\":\"https://evil.com\"}"}""", """{"fetchedAt":1,"raw":"nope"}""", """{"raw":"x"}""")) {
            cacheFile.writeText(junk)
            assertNull(junk, service(FakeHttp(), Clock()).state.value.cachedOrigin)
        }
        val http = FakeHttp().apply { response = blob("wss://a.vmd1.dev") }
        service(http, Clock()).tick()
        assertEquals("wss://a.vmd1.dev", service(FakeHttp(), Clock()).state.value.cachedOrigin)
    }

    @Test
    fun theRealHttpLayerOnlyAcceptsHttpsOrDebugLoopback() {
        assertTrue(OkHttpRelayDirectoryHttp.isAcceptable("https://gossip.vmd1.dev/x", false))
        assertFalse(OkHttpRelayDirectoryHttp.isAcceptable("http://gossip.vmd1.dev/x", true))
        assertFalse(OkHttpRelayDirectoryHttp.isAcceptable("http://127.0.0.1:1/x", false))
        assertTrue(OkHttpRelayDirectoryHttp.isAcceptable("http://127.0.0.1:1/x", true))
        assertFalse(OkHttpRelayDirectoryHttp.isAcceptable("https://u:p@gossip.vmd1.dev/x", false))
        assertFalse(OkHttpRelayDirectoryHttp.isAcceptable("file:///etc/passwd", true))
        assertTrue(OkHttpRelayDirectoryHttp.sameOrigin("https://a.vmd1.dev/x", "https://a.vmd1.dev/y"))
        assertFalse(OkHttpRelayDirectoryHttp.sameOrigin("https://a.vmd1.dev/x", "https://b.vmd1.dev/x"))
        assertFalse(OkHttpRelayDirectoryHttp.sameOrigin("https://a.vmd1.dev/x", "http://a.vmd1.dev/x"))
    }
}
