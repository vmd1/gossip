package dev.vmd1.gossip.features.messages

import dev.vmd1.gossip.protocol.Envelope
import dev.vmd1.gossip.transport.EnvelopeHandler
import dev.vmd1.gossip.transport.MessageRouter
import dev.vmd1.gossip.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

/**
 * The phone side of the Messages app (`messages.*`, see `schema/message-types.md`): answers a paired Mac's thread-list,
 * history and send requests from a [MessagesBackend], and publishes the `messages.state` slot (newest message time and
 * unread count, never content) so the Mac knows when to refetch.
 *
 * Off by default ([isEnabled] is a per-device switch in Settings). Requests are queries, so a duplicate just gets the
 * same answer again; **`messages.send` is not naturally idempotent** (a duplicate would text someone twice), so every
 * send carries a per-attempt `attemptId` kept with its result in a bounded recently-handled cache and a repeat only
 * re-sends the stored result. The slot is republished by a 60 s resync (and by [notifyChanged] on a new message), and the
 * core ignores an unchanged value.
 */
class MessagesBridge(
    private val selfId: String,
    private val scope: CoroutineScope,
    private val backend: MessagesBackend,
    private val send: (Envelope) -> Unit,
    private val publishState: (JsonObject?) -> Unit,
    private val isEnabled: () -> Boolean,
) {
    private val recentSends = object : LinkedHashMap<String, String?>() {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, String?>?) = size > RECENT_SENDS
    }
    private var lastPublished: JsonObject? = null

    fun register(router: MessageRouter) {
        router.register("messages.", EnvelopeHandler { handle(it) })
    }

    /** Starts the periodic resync of the state slot. */
    fun start() {
        scope.launch {
            while (true) {
                publish()
                delay(RESYNC_MS)
            }
        }
    }

    /** A message arrived or was sent: publish the new state now. */
    fun notifyChanged() = scope.launch { publish() }

    @Synchronized
    internal fun publish() {
        val state: JsonObject? = if (isEnabled() && backend.hasPermission()) {
            val s = backend.summary()
            buildJsonObject {
                put("latest", JsonPrimitive(s.latest)); put("unread", JsonPrimitive(s.unread)); put("threads", JsonPrimitive(s.threads))
            }
        } else null // switched off or no permission: clear the slot so the Mac shows nothing
        if (state == lastPublished) return
        lastPublished = state
        publishState(state)
    }

    internal fun handle(envelope: Envelope) {
        val requestId = envelope.payload.str("requestId")
        when (envelope.type) {
            THREADS_REQUEST -> requestId?.let { reply(envelope, THREADS, it) { threadsPayload(envelope.payload) } }
            HISTORY_REQUEST -> requestId?.let { reply(envelope, HISTORY, it) { historyPayload(envelope.payload) } }
            SEND -> envelope.payload.str("attemptId")?.let { onSend(envelope, it) }
            CONTACTS_REQUEST -> requestId?.let { onContacts(envelope, it) }
        }
    }

    private fun reply(request: Envelope, type: String, requestId: String, body: () -> Map<String, JsonElement>) {
        val payload = when {
            !isEnabled() -> mapOf("reason" to JsonPrimitive("disabled"))
            !backend.hasPermission() -> mapOf("reason" to JsonPrimitive("no_permission"))
            else -> runCatching(body).getOrElse { Log.w(TAG, "$type failed: ${it.message}"); mapOf("reason" to JsonPrimitive("failed")) }
        }
        send(
            Envelope(
                type = type, senderId = selfId, recipientId = request.senderId, ttl = 4,
                payload = JsonObject(payload + ("requestId" to JsonPrimitive(requestId)))
            )
        )
    }

    private fun threadsPayload(p: JsonObject): Map<String, JsonElement> {
        val limit = (p.long("limit") ?: 50L).toInt().coerceIn(1, MAX_THREADS)
        val threads = backend.threads(limit)
        return mapOf("threads" to JsonArray(capped(threads.map { t ->
            buildJsonObject {
                put("id", JsonPrimitive(t.id)); put("address", JsonPrimitive(t.address))
                t.name?.let { put("name", JsonPrimitive(it)) }
                put("snippet", JsonPrimitive(t.snippet)); put("date", JsonPrimitive(t.date))
                put("outgoing", JsonPrimitive(t.outgoing)); put("unread", JsonPrimitive(t.unread))
            }
        })))
    }

    private fun historyPayload(p: JsonObject): Map<String, JsonElement> {
        val threadId = p.str("threadId") ?: return mapOf("reason" to JsonPrimitive("invalid"))
        val limit = (p.long("limit") ?: 50L).toInt().coerceIn(1, MAX_HISTORY)
        val messages = backend.history(threadId, limit, p.long("before"))
        return mapOf(
            "threadId" to JsonPrimitive(threadId),
            "messages" to JsonArray(capped(messages.map { m ->
                buildJsonObject {
                    put("id", JsonPrimitive(m.id)); put("date", JsonPrimitive(m.date))
                    put("outgoing", JsonPrimitive(m.outgoing)); put("body", JsonPrimitive(m.body.take(MAX_BODY)))
                }
            }))
        )
    }

    /** Keeps a reply under [MAX_REPLY_BYTES] by dropping the oldest entries (lists are newest first). */
    private fun capped(items: List<JsonObject>): List<JsonObject> {
        var total = 0
        return items.takeWhile { total += it.toString().length; total <= MAX_REPLY_BYTES }
    }

    /** `messages.contacts_request`: the contacts with numbers, so the Mac can offer names while typing a recipient. A pure
     *  query. `haveDigest` is the digest of the list the Mac already stores; if it still matches, only `unchanged` is
     *  sent. Otherwise the whole list is sent in pages that each fit one envelope (the Mac replaces its copy once it has
     *  every page of a digest, so a repeated or reordered delivery changes nothing). */
    private fun onContacts(request: Envelope, requestId: String) {
        val reason = when {
            !isEnabled() -> "disabled"
            !backend.hasPermission() -> "no_permission"
            else -> null
        }
        val list = if (reason == null) runCatching { backend.contacts() }.getOrNull() else null
        fun reply(fields: Map<String, JsonElement>) = send(
            Envelope(type = CONTACTS, senderId = selfId, recipientId = request.senderId, ttl = 4,
                payload = JsonObject(fields + ("requestId" to JsonPrimitive(requestId))))
        )
        if (reason != null) return reply(mapOf("reason" to JsonPrimitive(reason)))
        if (list == null) return reply(mapOf("reason" to JsonPrimitive("no_contacts_permission")))
        val digest = contactsDigest(list)
        if (request.payload.str("haveDigest") == digest) return reply(mapOf("digest" to JsonPrimitive(digest), "unchanged" to JsonPrimitive(true)))
        val pages = list.chunked(CONTACTS_PER_PAGE).ifEmpty { listOf(emptyList()) }
        pages.forEachIndexed { index, page ->
            reply(mapOf(
                "digest" to JsonPrimitive(digest), "page" to JsonPrimitive(index), "pages" to JsonPrimitive(pages.size),
                "contacts" to JsonArray(page.map { c ->
                    buildJsonObject {
                        put("id", JsonPrimitive(c.id)); put("name", JsonPrimitive(c.name.take(80)))
                        put("numbers", JsonArray(c.numbers.map { JsonPrimitive(it.take(32)) }))
                    }
                })
            ))
        }
    }

    private fun onSend(envelope: Envelope, attemptId: String) {
        val cached: Pair<Boolean, String?>? = synchronized(recentSends) {
            if (recentSends.containsKey(attemptId)) true to recentSends[attemptId] else null
        }
        val reason: String? = if (cached != null) {
            cached.second // a repeat: re-send the stored result, send nothing
        } else if (!isEnabled()) {
            "disabled"
        } else {
            val address = envelope.payload.str("address")
            val body = envelope.payload.str("body")
            val failure = if (address == null || body == null || body.length > MAX_SEND) MessagesBackend.Failure.INVALID else backend.send(address, body)
            val r = failure?.name?.lowercase()
            synchronized(recentSends) { recentSends[attemptId] = r }
            if (failure == null) notifyChanged()
            r
        }
        send(
            Envelope(
                type = SEND_RESULT, senderId = selfId, recipientId = envelope.senderId, ttl = 4,
                payload = buildJsonObject {
                    put("attemptId", JsonPrimitive(attemptId)); put("ok", JsonPrimitive(reason == null))
                    reason?.let { put("reason", JsonPrimitive(it)) }
                }
            )
        )
    }

    /** A short fingerprint of the contact list (order-independent), so the Mac can tell whether its copy is current. */
    internal fun contactsDigest(list: List<Contact>): String {
        val text = list.map { c -> c.id + "|" + c.name + "|" + c.numbers.sorted().joinToString(",") }.sorted().joinToString("\n")
        return java.security.MessageDigest.getInstance("SHA-256").digest(text.toByteArray()).take(12)
            .joinToString("") { "%02x".format(it) }
    }

    private fun JsonObject.str(key: String) = this[key]?.jsonPrimitive?.contentOrNull?.takeIf { it.isNotEmpty() }
    private fun JsonObject.long(key: String) = this[key]?.jsonPrimitive?.longOrNull

    companion object {
        private const val TAG = "MessagesBridge"
        const val SLOT = "messages.state"
        const val THREADS_REQUEST = "messages.threads_request"
        const val THREADS = "messages.threads"
        const val HISTORY_REQUEST = "messages.history_request"
        const val HISTORY = "messages.history"
        const val SEND = "messages.send"
        const val SEND_RESULT = "messages.send_result"
        const val CONTACTS_REQUEST = "messages.contacts_request"
        const val CONTACTS = "messages.contacts"
        private const val CONTACTS_PER_PAGE = 250
        private const val RECENT_SENDS = 128
        private const val RESYNC_MS = 60_000L
        private const val MAX_THREADS = 100
        private const val MAX_HISTORY = 200
        private const val MAX_BODY = 2000
        private const val MAX_SEND = 1600
        private const val MAX_REPLY_BYTES = 48 * 1024
    }
}
