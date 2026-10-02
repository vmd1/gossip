package dev.vmd1.gossip.features.universalcontrol

import android.util.Log
import dev.vmd1.gossip.protocol.Envelope
import dev.vmd1.gossip.protocol.MessageType
import dev.vmd1.gossip.transport.EnvelopeHandler
import dev.vmd1.gossip.transport.MessageRouter
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive

/**
 * The Android side of the Universal Control session protocol: `control.session_start` -> `control.ready` /
 * `control.error`, and `control.end` (see `schema/message-types.md`). All `control.*` envelopes are targeted
 * with `ttl: 0` (never relayed) because `session_start` carries the key material.
 *
 * **Idempotent by construction** (repo `CLAUDE.md`): a duplicate `session_start` for the active session just
 * re-sends `control.ready` (the Mac re-sends it until it gets `ready`, which is also how a lost `ready`
 * recovers); a duplicate/late `control.end` is a no-op; and a bounded recently-ended cache stops a delayed
 * duplicate `session_start` from resurrecting a session the Mac already ended. A new `sessionId` replaces any
 * active session (the Mac reconnecting). Session-scoped, not persistent configuration, so no periodic resync:
 * the Mac owns reconciliation (it re-negotiates whenever its warm session is not ready).
 */
class ControlSessionState(
    private val selfId: String,
    private val scope: CoroutineScope,
    private val shizukuReady: () -> Boolean,
    private val send: (Envelope) -> Unit,
    private val sessionFactory: (sessionId: String, secret: ByteArray, onEnded: () -> Unit) -> ControlSessionHandle,
    private val isEnabled: () -> Boolean = { true },
    private val warn: (String, Throwable) -> Unit = { m, t -> Log.w(TAG, m, t) },
) {
    private class Active(val sessionId: String, val requester: String) {
        var session: ControlSessionHandle? = null
        var ready: ControlSessionHandle.Ready? = null
    }

    private val lock = Any()
    private var active: Active? = null
    private val recentlyEnded = LinkedHashSet<String>()

    val activeSessionId: String? get() = synchronized(lock) { active?.sessionId }

    fun register(router: MessageRouter) {
        current = this
        router.register(CONTROL_SESSION_START, EnvelopeHandler { onSessionStart(it) })
        router.register(CONTROL_END, EnvelopeHandler { onEnd(it) })
    }

    /** Entry point for the debug-only adb receiver (`internal` members aren't visible across the debug source set boundary by name). */
    fun handleDebug(envelope: Envelope) {
        if (envelope.type == CONTROL_END) onEnd(envelope) else onSessionStart(envelope)
    }

    internal fun onSessionStart(envelope: Envelope) {
        val sessionId = envelope.payload.str("sessionId") ?: return
        val secret = envelope.payload.str("secret")?.let { runCatching { java.util.Base64.getDecoder().decode(it) }.getOrNull() }
        if (!isEnabled()) return reply(envelope.senderId, CONTROL_ERROR, sessionId, "reason" to "feature_disabled")
        if (secret == null || secret.size != 32) return reply(envelope.senderId, CONTROL_ERROR, sessionId, "reason" to "bad_secret")
        val entry: Active
        synchronized(lock) {
            if (sessionId in recentlyEnded) return
            val cur = active
            if (cur?.sessionId == sessionId) {
                cur.ready?.let { sendReady(cur.requester, sessionId, it) }
                return
            }
            cur?.let { endLocked(it) }
            entry = Active(sessionId, envelope.senderId)
            active = entry
        }
        scope.launch(Dispatchers.IO) { launchSession(entry, secret) }
    }

    private fun launchSession(entry: Active, secret: ByteArray) {
        if (!shizukuReady()) return fail(entry, "shizuku_unavailable")
        val session = sessionFactory(entry.sessionId, secret) { onSessionEnded(entry) }
        synchronized(lock) {
            if (active !== entry) { session.close(); return }
            entry.session = session
        }
        val ready = try {
            session.start()
        } catch (t: Throwable) {
            warn("[${entry.sessionId}] control start failed", t)
            fail(entry, "start_failed") // before close(): close() fires onEnded, which would clear `active` first
            session.close()
            return
        }
        synchronized(lock) {
            if (active !== entry) { session.close(); return }
            entry.ready = ready
            sendReady(entry.requester, entry.sessionId, ready)
        }
    }

    internal fun onEnd(envelope: Envelope) {
        val sessionId = envelope.payload.str("sessionId") ?: return
        synchronized(lock) {
            remember(sessionId)
            active?.takeIf { it.sessionId == sessionId }?.let { endLocked(it) }
        }
    }

    private fun onSessionEnded(entry: Active) {
        val tellMac: Boolean
        synchronized(lock) {
            tellMac = active === entry
            if (tellMac) { active = null; remember(entry.sessionId) }
        }
        // The session ended on its own (Mac vanished, Shizuku died): say so, so the Mac re-negotiates promptly.
        if (tellMac) reply(entry.requester, CONTROL_END, entry.sessionId)
    }

    private fun fail(entry: Active, reason: String) {
        synchronized(lock) {
            if (active !== entry) return
            active = null; remember(entry.sessionId)
        }
        reply(entry.requester, CONTROL_ERROR, entry.sessionId, "reason" to reason)
    }

    /** Caller holds [lock]. */
    private fun endLocked(entry: Active) {
        if (active === entry) active = null
        remember(entry.sessionId)
        entry.session?.let { s -> Thread { runCatching { s.close() } }.start() } // close() may block on process teardown
    }

    private fun remember(sessionId: String) {
        recentlyEnded.add(sessionId)
        while (recentlyEnded.size > RECENT_CACHE) recentlyEnded.remove(recentlyEnded.first())
    }

    private fun sendReady(to: String, sessionId: String, r: ControlSessionHandle.Ready) {
        send(
            Envelope(
                type = CONTROL_READY, senderId = selfId, recipientId = to, ttl = 0,
                payload = buildJsonObject {
                    put("sessionId", JsonPrimitive(sessionId)); put("port", JsonPrimitive(r.port))
                    put("width", JsonPrimitive(r.info.width)); put("height", JsonPrimitive(r.info.height))
                    put("rotation", JsonPrimitive(r.info.rotation)); put("backend", JsonPrimitive(r.backend))
                }
            )
        )
    }

    private fun reply(to: String, type: String, sessionId: String, vararg extra: Pair<String, String>) {
        send(
            Envelope(
                type = type, senderId = selfId, recipientId = to, ttl = 0,
                payload = buildJsonObject {
                    put("sessionId", JsonPrimitive(sessionId))
                    extra.forEach { (k, v) -> put(k, JsonPrimitive(v)) }
                }
            )
        )
    }

    private fun JsonObject.str(key: String) = this[key]?.jsonPrimitive?.contentOrNull?.takeIf { it.isNotEmpty() }

    companion object {
        private const val TAG = "ControlSession"
        /** The live instance, so the debug-only adb receiver can start a session without the mesh. */
        @Volatile var current: ControlSessionState? = null
        private const val RECENT_CACHE = 64
        const val CONTROL_SESSION_START = "control.session_start"
        const val CONTROL_READY = "control.ready"
        const val CONTROL_END = "control.end"
        const val CONTROL_ERROR = "control.error"
    }
}
