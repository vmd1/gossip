package dev.vmd1.gossip.transport

import dev.vmd1.gossip.util.Log
import okhttp3.ConnectionSpec
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

private const val TAG = "RelayConnection"

/**
 * The one WebSocket to the relay, as a thin adapter over OkHttp. It owns no protocol: the Rust engine decides when to
 * connect, what to send and when to give up ([CoreBridge] relay actions); this class opens the socket, delivers what
 * arrives and writes what the engine returns. Mirrors the Mac's `RelayConnection`.
 *
 * Threading: the callbacks run on OkHttp's reader thread, which delivers a socket's events one at a time and in order
 * (open, then each message, then the close). The owner takes its engine lock inside them, exactly as the LAN socket
 * readers do. The `send*` methods are called under that lock, in the order the engine produced the bytes; a single
 * writer thread drains them in that order, so the order on the wire is the order of the engine's output (the Noise
 * nonces depend on it) while a slow relay never blocks the lock.
 *
 * Lifetime: one instance per connection attempt. [close] detaches it, so a late callback from a socket the engine already
 * abandoned can never reach the next connection, and [onClosed] is not called for a close we asked for.
 */
class RelayConnection(
    /** Must already have passed [RelayEndpointPolicy.validateConnectUrl]. */
    url: String,
    allowInsecureLoopback: Boolean,
    private val onOpen: () -> Unit,
    private val onText: (String) -> Unit,
    private val onBinary: (ByteArray) -> Unit,
    private val onClosed: () -> Unit
) {
    private sealed class Outgoing(val size: Int) {
        class Text(val text: String) : Outgoing(text.length)
        class Binary(val bytes: ByteArray) : Outgoing(bytes.size)
        object Stop : Outgoing(0)
    }

    @Volatile private var detached = false
    private val opened = AtomicBoolean(false)
    private val pending = LinkedBlockingQueue<Outgoing>()
    private val pendingBytes = AtomicLong(0)
    private val webSocket: WebSocket
    private val writer: Thread

    init {
        val specs = if (allowInsecureLoopback) listOf(ConnectionSpec.MODERN_TLS, ConnectionSpec.CLEARTEXT) else listOf(ConnectionSpec.MODERN_TLS)
        val client = BASE_CLIENT.newBuilder()
            .connectionSpecs(specs)
            .connectTimeout(CONNECT_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .callTimeout(0, TimeUnit.SECONDS)
            // A relay never redirects; following one would send the join to a host that was not validated.
            .followRedirects(false)
            .followSslRedirects(false)
            // OkHttp pings on this interval and fails the socket when a pong does not come back before the next one.
            .pingInterval(PING_INTERVAL_SECONDS, TimeUnit.SECONDS)
            .retryOnConnectionFailure(false)
            .build()
        webSocket = client.newWebSocket(Request.Builder().url(url).build(), Listener())
        writer = Thread({ writeLoop() }, "relay-writer").apply { isDaemon = true; start() }
    }

    // ---- Sending (called under the owner's engine lock) ---------------------------------------------------------

    fun sendText(text: String) = enqueue(Outgoing.Text(text))

    fun sendBinary(bytes: ByteArray) = enqueue(Outgoing.Binary(bytes))

    private fun enqueue(message: Outgoing) {
        if (detached) return
        if (pendingBytes.addAndGet(message.size.toLong()) > MAX_QUEUED_BYTES) {
            Log.w(TAG, "Relay is not accepting data; dropping the connection")
            // Not inline: we are under the owner's engine lock, in the middle of carrying out a batch of actions.
            Thread({ failed() }, "relay-overflow").start()
            return
        }
        pending.add(message)
    }

    private fun writeLoop() {
        try {
            while (!detached) {
                val message = pending.take()
                if (message === Outgoing.Stop || detached) return
                pendingBytes.addAndGet(-message.size.toLong())
                // OkHttp refuses (and closes the socket) once more than 16 MiB is queued: wait for it to drain instead.
                while (!detached && message.size > 0 && webSocket.queueSize() > 0 && webSocket.queueSize() + message.size > OKHTTP_QUEUE_LIMIT) {
                    Thread.sleep(5)
                }
                if (detached) return
                val ok = when (message) {
                    is Outgoing.Text -> webSocket.send(message.text)
                    is Outgoing.Binary -> webSocket.send(message.bytes.toByteString())
                    Outgoing.Stop -> true
                }
                if (!ok) {
                    // Also what a single message larger than OkHttp's 16 MiB queue limit ends up as.
                    Log.w(TAG, "Relay send was refused")
                    failed()
                    return
                }
            }
        } catch (e: InterruptedException) {
            // closed
        }
    }

    // ---- Closing -------------------------------------------------------------------------------------------------

    /** Detaches and closes the socket without reporting back (the engine asked for it, or this is teardown). */
    fun close() {
        if (detached) return
        detached = true
        pending.clear()
        pending.add(Outgoing.Stop)
        webSocket.cancel()
    }

    /** The socket died by itself: tell the owner once, then release everything. */
    private fun failed() {
        if (detached) return
        close()
        onClosed()
    }

    private inner class Listener : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            if (detached || !opened.compareAndSet(false, true)) return
            this@RelayConnection.onOpen()
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            if (!detached) onText(text)
        }

        override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
            if (!detached) onBinary(bytes.toByteArray())
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            failed()
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            failed()
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            // The message can carry the address; the class name is enough to diagnose.
            if (!detached) Log.w(TAG, "Relay socket ended: ${t.javaClass.simpleName}")
            failed()
        }
    }

    companion object {
        /** Shared so that each connection attempt reuses OkHttp's threads instead of creating a new pool. */
        private val BASE_CLIENT: OkHttpClient by lazy { OkHttpClient() }

        const val PING_INTERVAL_SECONDS = 30L
        const val CONNECT_TIMEOUT_SECONDS = 15L

        /** The most we hold for a relay that stopped reading (a frame may be up to 16 MiB). */
        private const val MAX_QUEUED_BYTES = 64L * 1024 * 1024
        private const val OKHTTP_QUEUE_LIMIT = 16L * 1024 * 1024
    }
}
