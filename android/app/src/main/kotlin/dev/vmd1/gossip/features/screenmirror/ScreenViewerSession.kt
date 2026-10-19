package dev.vmd1.gossip.features.screenmirror

import android.util.Base64
import dev.vmd1.gossip.protocol.Envelope
import dev.vmd1.gossip.protocol.MessageType
import dev.vmd1.gossip.transport.EnvelopeHandler
import dev.vmd1.gossip.transport.TransportManager
import dev.vmd1.gossip.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

private const val TAG = "ScreenViewer"

/**
 * Viewer side of on-device screen mirroring for an *Android* viewer (the Mac's counterpart is `ScreenMirrorController`).
 * Negotiates over the mesh (`screen.start` → `screen.ready` / `screen.error`, re-sending `screen.start` with the same
 * `sessionId` until the reply arrives, since the phone treats it idempotently), dials the source's bridge, authenticates
 * with a sealed hello, then delivers the stream through [Listener]. Everything but [Listener] runs off the main thread.
 */
class ScreenViewerSession(
    private val transport: TransportManager,
    private val selfId: String,
    private val deviceId: String,
    private val deviceName: String,
    private val scope: CoroutineScope,
    private val listener: Listener,
) {
    interface Listener {
        fun onHeader(header: BridgeStreamHeader)
        fun onMessage(message: BridgeMessage)
        /** The session is over. [error] is a user-facing reason, or `null` for a normal end (we or the source stopped it). */
        fun onEnded(error: String?)
    }

    val sessionId: String = UUID.randomUUID().toString()
    private val ended = AtomicBoolean(false)
    private val connecting = AtomicBoolean(false)
    @Volatile private var client: WebSocketClient? = null
    @Volatile private var cipher: ScreenCipher? = null
    private val sealLock = Any()
    private var retryJob: Job? = null
    private val handler = EnvelopeHandler { onEnvelope(it) }

    fun start() {
        transport.messageRouter.register("screen.", handler)
        val address = transport.peerAddress(deviceId)
        if (address == null) return finish("$deviceName isn't connected directly. Screen mirroring needs the same network.")
        retryJob = scope.launch {
            val began = System.currentTimeMillis()
            while (!ended.get() && !connecting.get()) {
                if (System.currentTimeMillis() - began > READY_TIMEOUT_MS) {
                    return@launch finish("$deviceName didn't respond. Is Gossip updated there?", sendStop = true)
                }
                send(MessageType.SCREEN_START) {
                    put("maxSize", JsonPrimitive(1600)); put("bitRate", JsonPrimitive(8_000_000))
                    put("maxFps", JsonPrimitive(60)); put("audio", JsonPrimitive(true))
                }
                delay(RETRY_INTERVAL_MS)
            }
        }
    }

    /** Ends the session (idempotent), telling the source to stop capturing. */
    fun stop() = finish(null, sendStop = true)

    /** Sends raw scrcpy control-message bytes. Safe from any thread; dropped before the stream is up. */
    fun sendControl(bytes: ByteArray) {
        val c = cipher ?: return
        val ws = client ?: return
        synchronized(sealLock) {
            runCatching { ws.sendBinary(c.seal(byteArrayOf(KIND_BINARY) + bytes)) }
                .onFailure { Log.w(TAG, "control send failed: ${it.message}") }
        }
    }

    private fun onEnvelope(envelope: Envelope) {
        if (envelope.senderId != deviceId || envelope.payload["sessionId"]?.jsonPrimitive?.contentOrNull != sessionId) return
        when (envelope.type) {
            MessageType.SCREEN_READY -> {
                if (!connecting.compareAndSet(false, true)) return // idempotent: the source re-sends ready for each duplicate start
                val port = envelope.payload["port"]?.jsonPrimitive?.intOrNull
                val secret = runCatching { Base64.decode(envelope.payload["secret"]?.jsonPrimitive?.content ?: "", Base64.DEFAULT) }.getOrNull()
                if (port == null || secret == null || secret.size != 32) return finish("The device sent an invalid screen-mirroring reply.", sendStop = true)
                retryJob?.cancel()
                scope.launch(kotlinx.coroutines.Dispatchers.IO) { connect(port, secret) }
            }
            MessageType.SCREEN_ERROR -> finish(
                when (envelope.payload["reason"]?.jsonPrimitive?.contentOrNull) {
                    "shizuku_unavailable" -> "Shizuku isn't running on $deviceName. Start it (it needs re-activating after every reboot) and allow Gossip."
                    "feature_disabled" -> "Screen mirroring is turned off on $deviceName. Turn it on in Gossip's settings there."
                    "capture_failed" -> "$deviceName couldn't start screen capture. Check Shizuku and try again."
                    else -> "$deviceName couldn't start mirroring."
                }
            )
        }
    }

    private fun connect(port: Int, secret: ByteArray) {
        val address = transport.peerAddress(deviceId) ?: return finish("$deviceName disconnected.", sendStop = true)
        try {
            val c = ScreenCipher(secret, sessionId, deviceSide = false)
            val ws = WebSocketClient.connect(address, port, "/screen")
            cipher = c
            client = ws
            if (ended.get()) { ws.close(); return }
            synchronized(sealLock) { ws.sendBinary(c.seal(byteArrayOf(KIND_BINARY) + sessionId.toByteArray())) }
            var gotHeader = false
            while (!ended.get()) {
                val message = ws.readMessage() ?: break
                if (!message.isText && message.data.isEmpty()) continue
                val plain = try { c.open(message.data) } catch (_: Exception) { break } // forged, replayed or malformed
                if (plain.isEmpty()) continue
                val body = plain.copyOfRange(1, plain.size)
                when (plain[0]) {
                    KIND_TEXT -> if (!gotHeader) {
                        val header = BridgeStreamHeader.parse(String(body)) ?: break
                        if (header.codec != "h264") return finish("Unsupported video codec ${header.codec}.", sendStop = true)
                        gotHeader = true
                        listener.onHeader(header)
                    }
                    KIND_BINARY -> if (gotHeader) BridgeMessage.parse(body)?.let(listener::onMessage)
                }
            }
            finish(if (gotHeader) null else "Couldn't connect to $deviceName's screen stream.")
        } catch (e: Exception) {
            Log.w(TAG, "bridge connection failed", e)
            finish("Couldn't connect to $deviceName's screen stream.", sendStop = true)
        }
    }

    private fun finish(error: String?, sendStop: Boolean = false) {
        if (!ended.compareAndSet(false, true)) return
        retryJob?.cancel()
        runCatching { client?.close() }
        transport.messageRouter.unregister(handler)
        if (sendStop) scope.launch(kotlinx.coroutines.NonCancellable) { send(MessageType.SCREEN_STOP) {} }
        listener.onEnded(error)
    }

    private suspend fun send(type: String, extra: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit) {
        runCatching {
            transport.send(
                Envelope(
                    type = type, senderId = selfId, recipientId = deviceId, ttl = 0,
                    payload = buildJsonObject { put("sessionId", JsonPrimitive(sessionId)); extra() }
                )
            )
        }.onFailure { Log.w(TAG, "send $type failed: ${it.message}") }
    }

    companion object {
        private const val KIND_TEXT: Byte = 0x00
        private const val KIND_BINARY: Byte = 0x01
        private const val RETRY_INTERVAL_MS = 2_500L
        private const val READY_TIMEOUT_MS = 20_000L
    }
}
