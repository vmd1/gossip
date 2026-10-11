package dev.vmd1.gossip.transport

import dev.vmd1.gossip.util.Log
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import uniffi.gossip_ffi.DirectoryAction
import uniffi.gossip_ffi.RelayDirectoryScheduler
import uniffi.gossip_ffi.relayDirectoryDecide
import uniffi.gossip_ffi.relayDirectoryParse
import java.io.File
import java.net.URI
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

private const val TAG = "RelayDirectory"

/** Logging must never break the directory logic (and is not available in plain JVM unit tests). */
private fun warn(message: String) { runCatching { Log.w(TAG, message) } }

/** The HTTP layer of the relay directory, behind an interface so tests can fake it. Returns the raw body, or `null` for any failure. */
fun interface RelayDirectoryHttp {
    fun fetch(url: String): ByteArray?
}

/**
 * The real thing, OkHttp with the constraints the directory design requires: HTTPS only (plain `http://` to loopback in
 * debug builds for local testing), a redirect is followed only within the same host and scheme, a 10 s timeout, a 64 KiB body
 * cap, no cookies or credentials, and nothing identifying in the request (no device ids, no headers beyond a generic
 * User-Agent).
 */
class OkHttpRelayDirectoryHttp(private val allowInsecureLoopback: Boolean = RelayEndpointPolicy.allowsInsecureLoopback) : RelayDirectoryHttp {
    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(TIMEOUT_SECONDS, TimeUnit.SECONDS)
        .readTimeout(TIMEOUT_SECONDS, TimeUnit.SECONDS)
        .callTimeout(TIMEOUT_SECONDS, TimeUnit.SECONDS)
        .followRedirects(false)
        .followSslRedirects(false)
        .retryOnConnectionFailure(false)
        .cookieJar(okhttp3.CookieJar.NO_COOKIES)
        .connectionSpecs(
            if (allowInsecureLoopback) listOf(okhttp3.ConnectionSpec.MODERN_TLS, okhttp3.ConnectionSpec.CLEARTEXT)
            else listOf(okhttp3.ConnectionSpec.MODERN_TLS)
        )
        .build()

    override fun fetch(url: String): ByteArray? {
        var current = url
        // At most two same-host redirects are followed by hand.
        repeat(3) {
            if (!isAcceptable(current, allowInsecureLoopback)) return null
            val request = Request.Builder().url(current).header("User-Agent", "Gossip").build()
            try {
                client.newCall(request).execute().use { response ->
                    if (response.isRedirect) {
                        val next = response.header("Location")?.let { runCatching { response.request.url.resolve(it)?.toString() }.getOrNull() } ?: return null
                        if (!sameOrigin(current, next)) return null
                        current = next
                        return@use
                    }
                    if (response.code != 200) return null
                    val body = response.body ?: return null
                    if (body.contentLength() > MAX_BODY_BYTES) return null
                    val bytes = body.source().let { source ->
                        val buffer = okio.Buffer()
                        while (buffer.size <= MAX_BODY_BYTES) {
                            if (source.read(buffer, 8192) == -1L) break
                        }
                        if (buffer.size > MAX_BODY_BYTES) return null
                        buffer.readByteArray()
                    }
                    return bytes
                }
            } catch (e: Exception) {
                return null
            }
        }
        return null
    }

    companion object {
        const val TIMEOUT_SECONDS = 10L
        const val MAX_BODY_BYTES = 64L * 1024

        fun isAcceptable(url: String, allowInsecureLoopback: Boolean): Boolean {
            val uri = try { URI(url) } catch (e: Exception) { return false }
            val scheme = uri.scheme?.lowercase() ?: return false
            val host = uri.host?.lowercase() ?: return false
            if (uri.rawUserInfo != null) return false
            if (scheme == "https") return true
            return scheme == "http" && allowInsecureLoopback && RelayEndpointPolicy.isLoopback(host)
        }

        fun sameOrigin(a: String, b: String): Boolean = try {
            val x = URI(a); val y = URI(b)
            x.scheme.lowercase() == y.scheme.lowercase() && x.host.lowercase() == y.host.lowercase() && x.port == y.port
        } catch (e: Exception) { false }
    }
}

/** What Settings shows and what the transport follows. */
data class RelayDirectoryState(
    /** The relay named by the cached/polled directory, if any (already validated by the core). */
    val cachedOrigin: String? = null,
    /** Whether the last poll succeeded (so the answer is current, not just remembered). */
    val isFresh: Boolean = false,
    /** When the directory was last fetched successfully (survives restarts), epoch ms. */
    val lastSuccessMs: Long? = null,
    /** True until the first poll has finished, when polling is on and nothing is cached. */
    val awaitingFirstAnswer: Boolean = false
)

/**
 * Polls the relay directory, keeps the last good answer on disk and tells the transport which relay it names. Mirrors the
 * Mac's `RelayDirectoryService`.
 *
 * The core (`relay_directory.rs`, through [relayDirectoryDecide]) validates every blob and applies the rule that a failed or
 * invalid fetch never replaces or clears a valid cached copy; this class does the HTTP, the file and the bookkeeping. It has
 * no timer of its own: the transport's existing once-a-second engine loop (inside the foreground service) calls [tick], which
 * does nothing unless a poll is due, so polling never wakes the device by itself.
 */
class RelayDirectoryService(
    private val endpoint: String = RelayEndpointPolicy.DIRECTORY_ENDPOINT,
    private val http: RelayDirectoryHttp = OkHttpRelayDirectoryHttp(),
    private val cacheFile: File,
    private val allowInsecureLocal: Boolean = RelayEndpointPolicy.allowsInsecureLoopback,
    private val scheduler: RelayDirectoryScheduler = RelayDirectoryScheduler(),
    private val now: () -> Long = System::currentTimeMillis,
    private val fetchDispatcher: CoroutineDispatcher = Dispatchers.IO
) {
    private val scope = CoroutineScope(fetchDispatcher)
    private val inFlight = AtomicBoolean(false)
    private val lock = Any()

    // Guarded by [lock].
    private var cachedRaw: String? = null
    private var lastSuccessMs: Long? = null
    private var lastAttemptMs: Long? = null
    private var failures: UInt = 0u

    private val _state = MutableStateFlow(RelayDirectoryState())
    val state: StateFlow<RelayDirectoryState> = _state.asStateFlow()

    /** Polling is off entirely while the endpoint is still the placeholder (the built-in default is used). */
    val pollingEnabled: Boolean = !RelayEndpointPolicy.isDirectoryPlaceholder(endpoint) &&
        OkHttpRelayDirectoryHttp.isAcceptable(endpoint, allowInsecureLocal)

    init {
        loadCache()
        _state.value = _state.value.copy(awaitingFirstAnswer = pollingEnabled && _state.value.cachedOrigin == null)
    }

    /** A missing, unreadable or invalid cache file is ignored (never fatal); the next good fetch overwrites it. */
    private fun loadCache() {
        try {
            if (!cacheFile.isFile || cacheFile.length() > 128 * 1024) return
            val file = Json.parseToJsonElement(cacheFile.readText()).jsonObject
            val raw = file["raw"]?.jsonPrimitive?.contentOrNull ?: return
            val fetchedAt = file["fetchedAt"]?.jsonPrimitive?.longOrNull ?: return
            val origin = relayDirectoryParse(raw) ?: return
            synchronized(lock) { cachedRaw = raw; lastSuccessMs = fetchedAt }
            _state.value = RelayDirectoryState(cachedOrigin = origin, isFresh = false, lastSuccessMs = fetchedAt)
        } catch (e: Exception) {
            warn("Ignoring an unreadable relay directory cache")
        }
    }

    /** Atomic: write a temp file next to the cache, then rename over it. */
    private fun writeCache(raw: String, fetchedAt: Long) {
        try {
            val json = buildJsonObject {
                put("fetchedAt", JsonPrimitive(fetchedAt))
                put("raw", JsonPrimitive(raw))
            }
            cacheFile.parentFile?.mkdirs()
            val temp = File(cacheFile.parentFile, ".${cacheFile.name}.${System.nanoTime()}.tmp")
            try {
                temp.writeText(json.toString())
                Files.move(temp.toPath(), cacheFile.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            } finally {
                temp.delete()
            }
        } catch (e: Exception) {
            warn("Could not save the relay directory cache")
        }
    }

    /** Whether the user has the relay switched on; nothing is polled while it is off (set by the owner of the settings). */
    @Volatile var wanted: Boolean = false

    /**
     * Called from the engine loop. Polls on the first call after the relay is wanted (a launch), then on the core's schedule.
     */
    fun tick() {
        if (!wanted || !pollingEnabled || inFlight.get()) return
        val due = synchronized(lock) { scheduler.shouldPoll(now(), lastSuccessMs, lastAttemptMs, failures) }
        if (due) poll()
    }

    /** The relay socket failed to connect: the relay may have moved, so look at the directory (at most every 10 minutes). */
    fun noteRelayConnectFailure() {
        if (!wanted || !pollingEnabled || inFlight.get()) return
        val due = synchronized(lock) { scheduler.shouldPollAfterConnectFailure(now(), lastAttemptMs) }
        if (due) poll()
    }

    private fun poll() {
        if (!inFlight.compareAndSet(false, true)) return
        synchronized(lock) { lastAttemptMs = now() }
        scheduler.reroll()
        scope.launch {
            val body = try { http.fetch(endpoint) } catch (e: Exception) { null }
            try { finishPoll(body) } finally { inFlight.set(false) }
        }
    }

    private fun finishPoll(body: ByteArray?) {
        val raw = body?.let { bytes ->
            // Strict UTF-8: a body that is not text cannot be a directory.
            runCatching {
                Charsets.UTF_8.newDecoder().onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
                    .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
                    .decode(java.nio.ByteBuffer.wrap(bytes)).toString()
            }.getOrNull()
        }
        synchronized(lock) {
            val decision = relayDirectoryDecide(cachedRaw, raw)
            when (decision.action) {
                DirectoryAction.ADOPT -> {
                    failures = 0u
                    val fetchedAt = now()
                    if (raw != null) { writeCache(raw, fetchedAt); cachedRaw = raw }
                    lastSuccessMs = fetchedAt
                    _state.value = RelayDirectoryState(decision.relayServer, isFresh = true, lastSuccessMs = fetchedAt, awaitingFirstAnswer = false)
                }
                DirectoryAction.KEEP_CACHED, DirectoryAction.NO_DIRECTORY -> {
                    failures = failures + 1u
                    decision.rejection?.let { warn("Relay directory rejected: $it") }
                    _state.value = RelayDirectoryState(decision.relayServer, isFresh = false, lastSuccessMs = lastSuccessMs, awaitingFirstAnswer = false)
                }
            }
        }
    }

    companion object {
        @Volatile private var instance: RelayDirectoryService? = null

        /** The app-wide instance; its cache is a plain file in the app's private storage. */
        fun getInstance(context: android.content.Context): RelayDirectoryService = instance ?: synchronized(this) {
            instance ?: RelayDirectoryService(cacheFile = File(context.applicationContext.filesDir, "relay-directory.json")).also { instance = it }
        }
    }
}
