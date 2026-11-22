package dev.vmd1.gossip.features.filetransfer

import android.util.Log
import dev.vmd1.gossip.protocol.Envelope
import dev.vmd1.gossip.transport.EnvelopeHandler
import dev.vmd1.gossip.transport.MessageRouter
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import java.io.File
import java.io.InputStream
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap

data class IncomingOffer(val transferId: String, val peerId: String, val peerName: String, val name: String, val size: Long)

data class TransferInfo(val transferId: String, val peerId: String, val name: String, val size: Long, val outgoing: Boolean, val state: String, val bytes: Long)

/** Where outgoing bytes come from: a content Uri on Android, a plain file in tests. */
interface FileSource {
    val name: String
    val size: Long
    fun open(): InputStream
    /** [length] bytes starting at [offset]. */
    fun read(offset: Long, length: Int): ByteArray
}

/**
 * File transfer (`docs/plans/file-transfer.md`, `schema/message-types.md`'s `file.*` rows), the Android half of the protocol
 * the Windows app already speaks. The receiver must accept every offer; chunks are 1 MiB raw frames written at offset
 * `index * chunkSize` (a repeat is harmless); `file.accept(next)` is both the answer and the resume request; the sender
 * re-offers on every fresh connection and every 30 s while unanswered. Every handler is idempotent.
 *
 * The transport, the clock and the disk are injected, so the state machine runs in unit tests.
 */
class FileTransferManager(
    private val messageRouter: MessageRouter,
    private val scope: CoroutineScope,
    private val selfId: String,
    private val partDir: File,
    private val sendEnvelope: suspend (Envelope, ByteArray?) -> Unit,
    private val isConnected: (String) -> Boolean,
    private val pendingOutboundBytes: () -> Long,
    private val peerName: (String) -> String,
    /** Moves a finished, verified file into the user's Downloads and returns its final name, or null on failure. */
    private val saveToDownloads: (File, String) -> String?,
    private val freeSpace: () -> Long,
    /** Shows the accept prompt; the answer comes back through [respond]. */
    private val onOffer: (IncomingOffer) -> Unit,
    private val onChanged: (TransferInfo) -> Unit = {},
    private val now: () -> Long = System::currentTimeMillis,
    private val offerAnswerTimeoutMs: Long = 120_000,
    private val reofferEveryMs: Long = 30_000
) {
    private class Outgoing(val id: String, val peerId: String, val source: FileSource, val sha256: String) {
        @Volatile var state = "offered"
        val offeredAt = System.currentTimeMillis()
        @Volatile var sender: Job? = null
        @Volatile var sent = 0L
    }

    private class Incoming(val id: String, val peerId: String, val peerName: String, val name: String, val size: Long, val chunkSize: Int, val sha256: String, val part: File) {
        @Volatile var accepted = false
        val received = HashSet<Int>()
        var file: RandomAccessFile? = null
        @Volatile var promptJob: Job? = null
    }

    private val outgoing = ConcurrentHashMap<String, Outgoing>()
    private val incoming = ConcurrentHashMap<String, Incoming>()
    private val finished = LinkedHashSet<String>()
    private var reofferJob: Job? = null
    private val handler = EnvelopeHandler { envelope -> scope.launch { runCatching { handle(envelope, null) }.onFailure { warn("file message failed: ${it.message}") } } }

    fun start() {
        partDir.mkdirs()
        messageRouter.register("file.", handler)
        reofferJob?.cancel()
        reofferJob = scope.launch { while (true) { delay(reofferEveryMs); reoffer(null) } }
    }

    fun shutdown() {
        messageRouter.unregister(handler)
        reofferJob?.cancel()
        outgoing.values.forEach { it.sender?.cancel() }
        synchronized(incoming) { incoming.values.forEach { runCatching { it.file?.close() }; it.file = null } }
    }

    /** The raw follow-up handler for `file.chunk` (register with `TransportManager.setRawHandler`). */
    fun onRawChunk(envelope: Envelope, raw: ByteArray) {
        scope.launch { runCatching { handle(envelope, raw) }.onFailure { warn("file chunk failed: ${it.message}") } }
    }

    /** A trusted device finished connecting: re-offer whatever is still unfinished for it. */
    fun onPeerConnected(peerId: String) = scope.launch { reoffer(peerId) }

    // MARK: sending

    suspend fun sendFile(peerId: String, source: FileSource): String {
        require(source.size <= FileTransferRules.MAX_FILE_BYTES) { "Files over 2 GiB cannot be sent." }
        val digest = MessageDigest.getInstance("SHA-256")
        source.open().use { s -> val buf = ByteArray(64 * 1024); while (true) { val n = s.read(buf); if (n < 0) break; digest.update(buf, 0, n) } }
        val t = Outgoing(java.util.UUID.randomUUID().toString(), peerId, source, digest.digest().joinToString("") { "%02x".format(it) })
        outgoing[t.id] = t
        offer(t)
        changed(t)
        return t.id
    }

    fun cancel(transferId: String) {
        outgoing[transferId]?.let { t ->
            if (t.state in ACTIVE) { t.sender?.cancel(); t.state = "cancelled"; send(t.peerId, "file.cancel", buildJsonObject { put("transferId", t.id) }); changed(t) }
        }
        incoming.remove(transferId)?.let { i -> i.promptJob?.cancel(); discard(i); send(i.peerId, "file.cancel", buildJsonObject { put("transferId", i.id) }) }
    }

    private fun offer(t: Outgoing) = send(t.peerId, "file.offer", buildJsonObject {
        put("transferId", t.id); put("name", t.source.name); put("size", t.source.size); put("sha256", t.sha256); put("chunkSize", FileTransferRules.CHUNK_SIZE)
    })

    private fun reoffer(onlyPeer: String?) {
        for (t in outgoing.values) {
            if (t.state !in ACTIVE) continue
            if (onlyPeer != null && t.peerId != onlyPeer) continue
            if (now() - t.offeredAt > GIVE_UP_MS && t.state == "offered") { t.state = "failed"; changed(t); continue }
            if (!isConnected(t.peerId)) continue
            if (onlyPeer == null && t.state != "offered" && t.state != "waiting") continue
            offer(t)
        }
    }

    private fun startSending(t: Outgoing, from: Int) {
        t.sender?.cancel()
        t.sender = scope.launch {
            try {
                t.state = "sending"
                val count = FileTransferRules.chunkCount(t.source.size)
                for (i in from until count) {
                    while (pendingOutboundBytes() > MAX_QUEUED) {
                        if (!isConnected(t.peerId)) { t.state = "waiting"; changed(t); return@launch }
                        delay(20)
                    }
                    if (!isConnected(t.peerId)) { t.state = "waiting"; changed(t); return@launch }
                    val length = FileTransferRules.chunkLength(t.source.size, FileTransferRules.CHUNK_SIZE, i)
                    val bytes = t.source.read(i.toLong() * FileTransferRules.CHUNK_SIZE, length)
                    sendEnvelope(envelope(t.peerId, "file.chunk", buildJsonObject { put("transferId", t.id); put("index", i) }, true), bytes)
                    t.sent = maxOf(t.sent, i.toLong() * FileTransferRules.CHUNK_SIZE + length)
                    if (i % 4 == 0) changed(t)
                }
                t.state = "waiting"; changed(t) // waiting for file.complete
            } catch (e: CancellationException) { throw e } catch (e: Exception) { t.state = "waiting" }
        }
    }

    // MARK: handling

    private suspend fun handle(env: Envelope, raw: ByteArray?) {
        val p = env.payload
        when (env.type) {
            "file.offer" -> onOffer(env.senderId, p)
            "file.accept" -> onAccept(env.senderId, p)
            "file.reject" -> onReject(env.senderId, p)
            "file.chunk" -> if (raw != null) onChunk(env.senderId, p, raw)
            "file.complete" -> onComplete(env.senderId, p)
            "file.cancel" -> onCancel(env.senderId, p)
        }
    }

    private fun str(p: JsonObject, k: String) = p[k]?.jsonPrimitive?.contentOrNull

    private suspend fun onOffer(sender: String, p: JsonObject) {
        val id = str(p, "transferId") ?: return
        if (synchronized(finished) { id in finished }) { send(sender, "file.complete", buildJsonObject { put("transferId", id); put("ok", true) }); return }
        incoming[id]?.let { known -> if (known.peerId == sender && known.accepted) sendAccept(known); return } // never prompt twice
        val size = p["size"]?.jsonPrimitive?.longOrNull ?: return
        val chunk = p["chunkSize"]?.jsonPrimitive?.intOrNull ?: FileTransferRules.CHUNK_SIZE
        if (size < 0 || size > FileTransferRules.MAX_FILE_BYTES || chunk < 1024 || chunk > 8 * 1024 * 1024) return reject(sender, id, "too_large")
        if (incoming.size >= FileTransferRules.MAX_INCOMING) return reject(sender, id, "busy")
        if (freeSpace() < size + SPACE_MARGIN) return reject(sender, id, "no_space")
        val name = FileTransferRules.sanitizeName(str(p, "name") ?: "file")
        val t = Incoming(id, sender, peerName(sender), name, size, chunk, (str(p, "sha256") ?: "").lowercase(), File(partDir, "$id.part"))
        if (incoming.putIfAbsent(id, t) != null) return
        // Decline is the default after two minutes.
        t.promptJob = scope.launch { delay(offerAnswerTimeoutMs); if (!t.accepted && incoming.remove(id, t)) reject(sender, id, "declined") }
        onOffer(IncomingOffer(id, sender, t.peerName, name, size))
    }

    /** The user's answer to a prompt shown through `onOffer`. */
    fun respond(transferId: String, accept: Boolean) {
        val t = incoming[transferId] ?: return
        if (t.accepted) return
        t.promptJob?.cancel()
        if (!accept) { incoming.remove(transferId, t); reject(t.peerId, transferId, "declined"); return }
        synchronized(t) {
            // Whole chunks left in a .part file (a dropped connection, an app restart) are kept: that is what `next` resumes from.
            val have = if (t.part.exists()) minOf(t.part.length() / t.chunkSize, FileTransferRules.chunkCount(t.size, t.chunkSize).toLong()).toInt() else 0
            val f = RandomAccessFile(t.part, "rw")
            f.setLength(minOf(t.size, have.toLong() * t.chunkSize))
            t.file = f
            for (i in 0 until have) t.received.add(i)
            t.accepted = true
        }
        incomingChanged(t)
        if (t.size == 0L) { scope.launch { finish(t) }; return }
        sendAccept(t)
    }

    private fun sendAccept(t: Incoming) = send(t.peerId, "file.accept", buildJsonObject { put("transferId", t.id); put("next", FileTransferRules.nextIndex(synchronized(t) { t.received.toSet() })) })

    private fun reject(peer: String, id: String, reason: String) = send(peer, "file.reject", buildJsonObject { put("transferId", id); put("reason", reason) })

    private suspend fun onChunk(sender: String, p: JsonObject, raw: ByteArray) {
        val id = str(p, "transferId") ?: return
        val index = p["index"]?.jsonPrimitive?.intOrNull ?: return
        val t = incoming[id]?.takeIf { it.peerId == sender && it.accepted } ?: return // unknown or finished: dropped
        val done = synchronized(t) {
            val f = t.file ?: return
            val expected = FileTransferRules.chunkLength(t.size, t.chunkSize, index)
            if (index < 0 || expected == 0 || raw.size != expected) return
            f.seek(index.toLong() * t.chunkSize); f.write(raw)
            t.received.add(index)
            t.received.size == FileTransferRules.chunkCount(t.size, t.chunkSize)
        }
        if (index % 4 == 0 || done) incomingChanged(t)
        if (done) finish(t)
    }

    private fun finish(t: Incoming) {
        if (!incoming.remove(t.id, t)) return // already finished (a duplicate last chunk)
        var ok = false
        var finalName = t.name
        synchronized(t) {
            runCatching { t.file?.fd?.sync() }; runCatching { t.file?.close() }; t.file = null
            val digest = MessageDigest.getInstance("SHA-256")
            t.part.inputStream().use { s -> val buf = ByteArray(64 * 1024); while (true) { val n = s.read(buf); if (n < 0) break; digest.update(buf, 0, n) } }
            ok = digest.digest().joinToString("") { "%02x".format(it) } == t.sha256
            if (ok) { val saved = saveToDownloads(t.part, t.name); if (saved == null) ok = false else finalName = saved }
            t.part.delete()
        }
        synchronized(finished) { finished.add(t.id); while (finished.size > 128) finished.remove(finished.first()) }
        onChanged(TransferInfo(t.id, t.peerId, finalName, t.size, false, if (ok) "done" else "failed", if (ok) t.size else 0))
        send(t.peerId, "file.complete", buildJsonObject { put("transferId", t.id); put("ok", ok); if (!ok) put("reason", "hash_mismatch") })
    }

    private fun discard(t: Incoming) = synchronized(t) { runCatching { t.file?.close() }; t.file = null; t.part.delete() }

    private fun onAccept(sender: String, p: JsonObject) {
        val t = outgoing[str(p, "transferId")] ?: return
        if (t.peerId != sender || t.state !in ACTIVE) return
        val next = (p["next"]?.jsonPrimitive?.intOrNull ?: 0).coerceIn(0, FileTransferRules.chunkCount(t.source.size))
        if (t.source.size == 0L) return
        startSending(t, next) // a duplicate accept restarts from the same index
    }

    private fun onReject(sender: String, p: JsonObject) {
        val t = outgoing[str(p, "transferId")] ?: return
        if (t.peerId != sender || t.state == "done" || t.state == "cancelled") return
        t.sender?.cancel(); t.state = "rejected"; changed(t)
    }

    private fun onComplete(sender: String, p: JsonObject) {
        val t = outgoing[str(p, "transferId")] ?: return
        if (t.peerId != sender || t.state == "done" || t.state == "cancelled") return
        t.sender?.cancel()
        t.state = if (p["ok"]?.jsonPrimitive?.booleanOrNull == true) "done" else "failed"
        if (t.state == "done") t.sent = t.source.size
        changed(t)
    }

    private fun onCancel(sender: String, p: JsonObject) {
        val id = str(p, "transferId") ?: return
        incoming[id]?.let { i -> if (i.peerId == sender && incoming.remove(id, i)) { i.promptJob?.cancel(); discard(i); onChanged(TransferInfo(id, sender, i.name, i.size, false, "cancelled", 0)) } }
        outgoing[id]?.let { t -> if (t.peerId == sender && t.state in ACTIVE) { t.sender?.cancel(); t.state = "cancelled"; changed(t) } }
    }

    // MARK: helpers

    private fun warn(message: String) { runCatching { Log.w(TAG, message) } } // android.util.Log is absent in JVM unit tests

    private fun envelope(peer: String, type: String, payload: JsonObject, rawFollowup: Boolean = false) =
        Envelope(type = type, senderId = selfId, recipientId = peer, payload = payload, hasRawFollowup = rawFollowup)

    // Not being connected is normal (the peer left): the reconcile paths try again, so a failed send is not an error.
    private fun send(peer: String, type: String, payload: JsonObject) {
        scope.launch { runCatching { sendEnvelope(envelope(peer, type, payload), null) } }
    }

    private fun changed(t: Outgoing) = onChanged(TransferInfo(t.id, t.peerId, t.source.name, t.source.size, true, t.state, t.sent))
    private fun incomingChanged(t: Incoming) {
        val bytes = synchronized(t) { t.received.size.toLong() * t.chunkSize }
        onChanged(TransferInfo(t.id, t.peerId, t.name, t.size, false, if (t.accepted) "receiving" else "offered", minOf(bytes, t.size)))
    }

    companion object {
        private const val TAG = "FileTransfer"
        private val ACTIVE = setOf("offered", "sending", "waiting")
        private const val GIVE_UP_MS = 10 * 60 * 1000L
        private const val MAX_QUEUED = 8L * 1024 * 1024
        private const val SPACE_MARGIN = 100L * 1024 * 1024
    }
}
