package dev.vmd1.gossip.features.peripheral

import dev.vmd1.gossip.protocol.Envelope
import dev.vmd1.gossip.transport.TransportManager
import dev.vmd1.gossip.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObjectBuilder
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import java.util.UUID

/**
 * Sends `peripheral.input` to a paired Mac (see `schema/message-types.md`): this phone as its trackpad and keyboard.
 * Every message carries this session's `sessionId` and a strictly increasing `seq`, which is what lets the Mac drop a
 * duplicate or late delivery (relative moves and key presses are not idempotent). Messages are sent strictly in order
 * by a single coroutine, and pointer movement is coalesced so a fast swipe doesn't flood the link.
 */
class PeripheralInputSender(
    private val transport: TransportManager,
    private val selfId: String,
    private val macId: String,
    scope: CoroutineScope,
) {
    val sessionId: String = UUID.randomUUID().toString()
    private var seq = 0L
    private var pendingDx = 0f
    private var pendingDy = 0f
    private var pendingScrollX = 0f
    private var pendingScrollY = 0f
    private val queue = Channel<Envelope>(Channel.UNLIMITED)

    init {
        scope.launch {
            for (envelope in queue) {
                runCatching { transport.send(envelope) }.onFailure { Log.w(TAG, "send failed: ${it.message}") }
            }
        }
    }

    @Synchronized fun addMove(dx: Float, dy: Float) { pendingDx += dx; pendingDy += dy }
    @Synchronized fun addScroll(dx: Float, dy: Float) { pendingScrollX += dx; pendingScrollY += dy }

    /** Sends the coalesced movement/scroll accumulated so far (call on a short timer, and before any other event). */
    @Synchronized fun flush() {
        val dx = pendingDx.toInt(); val dy = pendingDy.toInt()
        if (dx != 0 || dy != 0) {
            pendingDx -= dx; pendingDy -= dy
            enqueue("move") { put("dx", JsonPrimitive(dx)); put("dy", JsonPrimitive(dy)) }
        }
        val sx = pendingScrollX.toInt(); val sy = pendingScrollY.toInt()
        if (sx != 0 || sy != 0) {
            pendingScrollX -= sx; pendingScrollY -= sy
            enqueue("scroll") { put("dx", JsonPrimitive(sx)); put("dy", JsonPrimitive(sy)) }
        }
    }

    @Synchronized fun click(button: Int, count: Int = 1) { flush(); enqueue("click") { put("button", JsonPrimitive(button)); put("count", JsonPrimitive(count)) } }
    @Synchronized fun button(button: Int, down: Boolean) { flush(); enqueue("button") { put("button", JsonPrimitive(button)); put("down", JsonPrimitive(down)) } }
    @Synchronized fun key(name: String) { flush(); enqueue("key") { put("key", JsonPrimitive(name)) } }
    @Synchronized fun text(text: String) { if (text.isEmpty()) return; flush(); enqueue("text") { put("text", JsonPrimitive(text)) } }

    fun close() = queue.close()

    private fun enqueue(kind: String, fields: JsonObjectBuilder.() -> Unit) {
        val n = ++seq
        queue.trySend(
            Envelope(
                type = TYPE, senderId = selfId, recipientId = macId, ttl = 4,
                payload = buildJsonObject {
                    put("sessionId", JsonPrimitive(sessionId)); put("seq", JsonPrimitive(n)); put("kind", JsonPrimitive(kind)); fields()
                }
            )
        )
    }

    companion object {
        const val TYPE = "peripheral.input"
        private const val TAG = "PeripheralInput"
    }
}
