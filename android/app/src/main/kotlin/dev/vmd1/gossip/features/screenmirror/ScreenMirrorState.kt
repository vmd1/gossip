package dev.vmd1.gossip.features.screenmirror

import dev.vmd1.gossip.util.Log
import dev.vmd1.gossip.protocol.Envelope
import dev.vmd1.gossip.protocol.MessageType
import dev.vmd1.gossip.transport.EnvelopeHandler
import dev.vmd1.gossip.transport.MessageRouter
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive

/**
 * The Android side of the screen-mirroring protocol (`screen.start` / `screen.stop` /
 * `screen.ready` / `screen.error`, see `schema/message-types.md`).
 *
 * A `screen.start` carrying a `sessionId` launches the on-device capture ([ScreenBridge]:
 * bundled scrcpy server via Shizuku + a WebSocket listener) and answers the requester with
 * `screen.ready` (port + secret). A `screen.start` *without* a `sessionId` is the legacy
 * signaling-only form (Mac drives `adb screenrecord` itself) and only flips [isMirroring].
 *
 * **Idempotent by construction** (repo `CLAUDE.md`): a duplicate `screen.start` for the active
 * `sessionId` starts nothing and just re-sends `screen.ready` (which also makes a lost
 * `screen.ready` recoverable — the viewer simply re-sends `screen.start`); a duplicate/late
 * `screen.stop` for a non-active session is a no-op; and a bounded recently-ended cache stops
 * a delayed duplicate `screen.start` from resurrecting a session the viewer already stopped
 * (or that already ended on its own). A session is session-scoped, not persistent
 * configuration, so there is no periodic resync: it self-heals by auto-ending when the viewer
 * disconnects or never attaches ([ScreenBridge.ATTACH_TIMEOUT_MS]).
 */
class ScreenMirrorState(
    private val selfId: String,
    private val scope: CoroutineScope,
    private val shizukuReady: () -> Boolean,
    private val send: (Envelope) -> Unit,
    private val sessionFactory: (sessionId: String, options: ScrcpyServerSession.Options, onEnded: () -> Unit) -> ScreenSession,
    private val logReadyToken: Boolean = false,
    /** Runs on the launch thread just before an app window starts: enables a disabled app and wakes the screen. Returns a
     *  `screen.error` reason (`app_enable_failed`) if the app can't be made launchable, else `null`. */
    private val prepareApp: (String) -> String? = { null },
    /** Why [pkg] can't be opened as a window (`app_unavailable`), or `null` if it can. */
    private val appChecker: (String) -> String? = { null },
    /** A 48 px PNG icon for [pkg], or `null`. */
    private val iconProvider: (String) -> ByteArray? = { null },
    /** The apps that can be opened as windows: (package, label) of every launchable app. */
    private val appLister: () -> List<AppInfo> = { emptyList() },
    /** Screen mirroring turned off on this device: refuse with `screen.error feature_disabled`. */
    private val isEnabled: () -> Boolean = { true },
    private val warn: (String, Throwable) -> Unit = { m, t -> Log.w(TAG, m, t) },
) {
    /** A launchable app: its package, label and `lastUpdateTime` (a version stamp: a changed value means a new icon may exist). */
    data class AppInfo(val pkg: String, val label: String, val version: Long, val disabled: Boolean = false)

    private class Active(val sessionId: String, val requester: String, val isApp: Boolean) {
        var session: ScreenSession? = null
        var ready: ScreenSession.Ready? = null
    }

    private val lock = Any()
    /** Live sessions, oldest first: at most one whole-screen mirror plus up to [MAX_APP_WINDOWS] app windows. */
    private val actives = LinkedHashMap<String, Active>()
    private val recentlyEnded = LinkedHashSet<String>()

    private val _isMirroring = MutableStateFlow(false)
    val isMirroring: StateFlow<Boolean> = _isMirroring

    /** Registers this instance's handlers with [router] for the `screen.` namespace. */
    fun register(router: MessageRouter) {
        router.register(MessageType.SCREEN_START, EnvelopeHandler { onScreenStart(it) })
        router.register(MessageType.SCREEN_STOP, EnvelopeHandler { onScreenStop(it) })
        router.register(MessageType.SCREEN_APPS_REQUEST, EnvelopeHandler { onAppsRequest(it) })
    }

    internal fun onScreenStart(envelope: Envelope) {
        val sessionId = envelope.payload.str("sessionId") ?: return
        if (!isEnabled()) {
            send(
                Envelope(
                    type = MessageType.SCREEN_ERROR, senderId = selfId, recipientId = envelope.senderId, ttl = 0,
                    payload = buildJsonObject {
                        put("sessionId", JsonPrimitive(sessionId)); put("reason", JsonPrimitive("feature_disabled"))
                    }
                )
            )
            return
        }
        val options = parseOptions(envelope.payload)
        options.startApp?.let { app ->
            appProblem(app)?.let { reason ->
                send(Envelope(type = MessageType.SCREEN_ERROR, senderId = selfId, recipientId = envelope.senderId, ttl = 0,
                    payload = buildJsonObject { put("sessionId", JsonPrimitive(sessionId)); put("reason", JsonPrimitive(reason)) }))
                return
            }
        }
        val entry: Active
        synchronized(lock) {
            if (sessionId in recentlyEnded) return
            val cur = actives[sessionId]
            if (cur != null) {
                cur.ready?.let { sendReady(cur.requester, sessionId, it) }
                return
            }
            if (options.isAppWindow) {
                // App windows run side by side on their own virtual displays; past the limit the oldest one makes room.
                val apps = actives.values.filter { it.isApp }
                if (apps.size >= MAX_APP_WINDOWS) endLocked(apps.first())
            } else {
                // A whole-screen mirror replaces the previous whole-screen mirror, never the app windows.
                actives.values.filter { !it.isApp }.forEach { endLocked(it) }
            }
            entry = Active(sessionId, envelope.senderId, options.isAppWindow)
            actives[sessionId] = entry
            publish()
        }
        scope.launch(kotlinx.coroutines.Dispatchers.IO) { launchSession(entry, options) }
    }

    /** `screen.apps_request`: answers with the launchable apps. A pure query, so a duplicate just gets the same answer. */
    internal fun onAppsRequest(envelope: Envelope) {
        val enabled = isEnabled()
        val apps = if (enabled) appLister().take(MAX_APPS) else emptyList()
        send(
            Envelope(
                type = MessageType.SCREEN_APPS, senderId = selfId, recipientId = envelope.senderId, ttl = 0,
                payload = buildJsonObject {
                    put("apps", kotlinx.serialization.json.JsonArray(apps.map { a ->
                        buildJsonObject {
                            put("package", JsonPrimitive(a.pkg)); put("label", JsonPrimitive(a.label.take(MAX_LABEL)))
                            put("v", JsonPrimitive(a.version))
                            if (a.disabled) put("disabled", JsonPrimitive(true))
                        }
                    }))
                    if (!enabled) put("reason", JsonPrimitive("feature_disabled"))
                }
            )
        )
        // Icons follow in batches (one envelope for all of them would be far too big). Each batch is a merge into the
        // viewer's icon table, so a repeated request or a duplicate batch changes nothing.
        if (enabled && envelope.payload["icons"]?.jsonPrimitive?.booleanOrNull == true) {
            // The viewer lists `pkg@version` for icons it already has; only missing or changed ones are sent.
            val have = (envelope.payload["haveIcons"] as? kotlinx.serialization.json.JsonArray)
                ?.mapNotNull { it.jsonPrimitive.contentOrNull }?.toHashSet() ?: emptySet()
            val missing = apps.filter { "${it.pkg}@${it.version}" !in have }
            scope.launch(kotlinx.coroutines.Dispatchers.IO) {
                for (batch in missing.chunked(ICON_BATCH)) {
                    val icons = batch.mapNotNull { a ->
                        runCatching { iconProvider(a.pkg) }.getOrNull()?.let { png ->
                            buildJsonObject {
                                put("package", JsonPrimitive(a.pkg)); put("v", JsonPrimitive(a.version))
                                put("png", JsonPrimitive(java.util.Base64.getEncoder().encodeToString(png)))
                            }
                        }
                    }
                    if (icons.isEmpty()) continue
                    send(Envelope(
                        type = MessageType.SCREEN_APP_ICONS, senderId = selfId, recipientId = envelope.senderId, ttl = 0,
                        payload = buildJsonObject { put("icons", kotlinx.serialization.json.JsonArray(icons)) }
                    ))
                }
            }
        }
    }

    private fun appProblem(pkg: String): String? = appChecker(pkg)

    private fun launchSession(entry: Active, options: ScrcpyServerSession.Options) {
        if (!shizukuReady()) return fail(entry, "shizuku_unavailable")
        options.startApp?.let { app -> prepareApp(app)?.let { reason -> return fail(entry, reason) } }
        val session = sessionFactory(entry.sessionId, options) { onSessionEnded(entry) }
        synchronized(lock) {
            if (actives[entry.sessionId] !== entry) { session.close(); return }
            entry.session = session
        }
        val ready = try {
            session.start()
        } catch (t: Throwable) {
            warn("[${entry.sessionId}] capture start failed", t)
            // fail() before close(): close() fires onEnded, which would clear `active` first and
            // make fail() think the session was already gone (swallowing the screen.error).
            fail(entry, "capture_failed")
            session.close()
            return
        }
        synchronized(lock) {
            if (actives[entry.sessionId] !== entry) { session.close(); return }
            entry.ready = ready
            sendReady(entry.requester, entry.sessionId, ready)
        }
    }

    /** Ends whatever session is active, from the on-device "Stop" action. The viewer sees its WebSocket close. */
    fun stopActive() {
        synchronized(lock) {
            actives.values.toList().forEach { endLocked(it) }
            publish()
        }
    }

    internal fun onScreenStop(envelope: Envelope) {
        val sessionId = envelope.payload.str("sessionId") ?: return
        synchronized(lock) {
            remember(sessionId)
            actives[sessionId]?.let { endLocked(it) }
            publish()
        }
    }

    private fun onSessionEnded(entry: Active) = synchronized(lock) {
        if (actives[entry.sessionId] === entry) { actives.remove(entry.sessionId); remember(entry.sessionId); publish() }
    }

    private fun fail(entry: Active, reason: String) {
        synchronized(lock) {
            if (actives[entry.sessionId] !== entry) return
            actives.remove(entry.sessionId); remember(entry.sessionId); publish()
            send(
                Envelope(
                    type = MessageType.SCREEN_ERROR, senderId = selfId, recipientId = entry.requester, ttl = 0,
                    payload = buildJsonObject {
                        put("sessionId", JsonPrimitive(entry.sessionId)); put("reason", JsonPrimitive(reason))
                    }
                )
            )
        }
    }

    /** Caller holds [lock]. */
    private fun endLocked(entry: Active) {
        if (actives[entry.sessionId] === entry) actives.remove(entry.sessionId)
        remember(entry.sessionId)
        entry.session?.let { s -> Thread { runCatching { s.close() } }.start() } // close() may block on process teardown
    }

    private fun remember(sessionId: String) {
        recentlyEnded.add(sessionId)
        while (recentlyEnded.size > RECENT_CACHE) recentlyEnded.remove(recentlyEnded.first())
    }

    /** Only a session showing the phone's own screen counts: an app window runs on a separate virtual display, so nobody is watching this screen. */
    private fun publish() { _isMirroring.value = actives.values.any { !it.isApp } }

    private fun sendReady(to: String, sessionId: String, r: ScreenSession.Ready) {
        if (logReadyToken) Log.d(TAG, "READY sessionId=$sessionId port=${r.port}")
        send(
            Envelope(
                type = MessageType.SCREEN_READY, senderId = selfId, recipientId = to, ttl = 0,
                payload = buildJsonObject {
                    put("sessionId", JsonPrimitive(sessionId))
                    put("port", JsonPrimitive(r.port)); put("secret", JsonPrimitive(r.secret))
                    put("width", JsonPrimitive(r.width)); put("height", JsonPrimitive(r.height))
                    put("codec", JsonPrimitive(r.codec))
                }
            )
        )
    }

    private fun parseOptions(p: JsonObject): ScrcpyServerSession.Options {
        val d = ScrcpyServerSession.Options()
        return ScrcpyServerSession.Options(
            maxSize = (p.int("maxSize") ?: d.maxSize).coerceIn(320, 2560),
            videoBitRate = (p.int("bitRate") ?: d.videoBitRate).coerceIn(500_000, 20_000_000),
            maxFps = (p.int("maxFps") ?: d.maxFps).coerceIn(1, 60),
            audio = p["audio"]?.jsonPrimitive?.booleanOrNull ?: d.audio,
            // An app window: a virtual display of `appSize` (default 1080x2340) at `appDpi` (default 420), and the app on it.
            // Both are validated here because they end up in a shell command line / a length-prefixed control message.
            startApp = p.str("app")?.takeIf { ScrcpyServerSession.Options.isValidPackage(it) },
            newDisplay = p.str("app")?.takeIf { ScrcpyServerSession.Options.isValidPackage(it) }?.let {
                val size = p.str("appSize")?.takeIf { s -> Regex("[0-9]{3,4}x[0-9]{3,4}").matches(s) } ?: "1080x2340"
                val dpi = (p.int("appDpi") ?: 420).coerceIn(120, 640)
                "$size/$dpi"
            },
        )
    }

    private fun JsonObject.str(key: String) = this[key]?.jsonPrimitive?.contentOrNull?.takeIf { it.isNotEmpty() }
    private fun JsonObject.int(key: String) = this[key]?.jsonPrimitive?.intOrNull

    companion object {
        private const val TAG = "ScreenMirror"
        private const val RECENT_CACHE = 64
        private const val MAX_APPS = 300
        const val MAX_APP_WINDOWS = 4
        private const val ICON_BATCH = 16
        private const val MAX_LABEL = 40
    }
}
