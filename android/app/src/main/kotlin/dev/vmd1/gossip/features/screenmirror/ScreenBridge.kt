package dev.vmd1.gossip.features.screenmirror

import android.content.Context
import android.util.Base64
import dev.vmd1.gossip.util.Log
import org.json.JSONObject
import java.io.Closeable
import java.io.IOException
import java.net.ServerSocket
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** What [ScreenMirrorState] needs from a session — an interface so its start/stop/idempotency
 *  logic is unit-testable without Shizuku or a device. */
interface ScreenSession : Closeable {
    /** [secret] is the base64 per-session key the viewer needs to talk to the bridge (see [ScreenCipher]). */
    data class Ready(val port: Int, val secret: String, val width: Int, val height: Int, val codec: String)
    val sessionId: String
    /** Blocking; throws if capture can't start. */
    fun start(): Ready
}

/**
 * One screen-mirroring session's Android-side bridge: owns the [ScrcpyServerSession] (scrcpy
 * server at shell UID via Shizuku) and a single-client WebSocket listener the viewer connects
 * to, and shuttles video/control between them. See `schema/message-types.md` (`screen.*`) and
 * `android/screen-server/README.md` for the contract.
 *
 * **Viewer wire format** (WebSocket, port from `screen.ready`): every WebSocket message in both
 * directions is *binary* and sealed by [ScreenCipher] (`[u64 BE counter][ChaCha20-Poly1305 ciphertext][tag]`,
 * key from the per-session `secret` delivered only inside the Noise-encrypted mesh). The plaintext starts with
 * a kind byte — `0x00` text, `0x01` binary — followed by the body:
 * - viewer → bridge, first message: binary, body = the session id (proves the viewer holds the secret).
 *   Anything else closes with 1008.
 * - bridge → viewer, text: `{"codec","width","height","deviceName","audio"}` once, right after auth;
 *   `audio` is `null` or `{"codec":"raw","sampleRate":48000,"channels":2,"format":"s16le"}`.
 * - bridge → viewer, binary, body's first byte = kind: `0x00` video packet (`u64 BE pts/flags`, then
 *   Annex-B H.264; flags bit 62 = config/SPS+PPS, bit 61 = key frame), `0x01` size change
 *   (`u32 BE width`, `u32 BE height`), `0x02` raw scrcpy device-message bytes (control socket),
 *   `0x03` audio packet (`u64 BE pts/flags`, then interleaved s16le PCM) — only when `audio` is non-null.
 * - viewer → bridge, binary after auth: raw scrcpy control messages (inject touch/key/scroll...),
 *   forwarded verbatim to the server's control socket.
 * On attach the bridge replays the cached size + config packet and sends scrcpy `RESET_VIDEO`
 * so a viewer that attaches late (the server starts at `screen.start`, before the viewer
 * connects) gets a key frame immediately even on a static screen.
 *
 * **Auth**: possession of the random 256-bit secret. Each accepted connection authenticates on its own
 * thread, so a stalled or junk connection can't delay the real viewer; the first to authenticate wins and the
 * listener closes.
 */
class ScreenBridge(
    private val context: Context,
    override val sessionId: String,
    private val options: ScrcpyServerSession.Options,
    private val onEnded: () -> Unit,
) : ScreenSession {

    private val secret: ByteArray = ByteArray(32).also { SecureRandom().nextBytes(it) }
    private val cipher = ScreenCipher(secret, sessionId, deviceSide = true)
    private val claimed = AtomicBoolean(false)
    private val ended = AtomicBoolean(false)
    @Volatile private var viewerAttached = false
    private val lock = Any()
    private var session: ScrcpyServerSession? = null
    private var listener: ServerSocket? = null
    private var client: WebSocketConnection? = null
    private var latestConfig: ByteArray? = null
    private var latestSize: ByteArray? = null

    /** Launches the scrcpy server and opens the listener; blocking. Throws if capture can't start. */
    override fun start(): ScreenSession.Ready {
        val s = ScrcpyServerSession.open(context, options)
        if (ended.get()) { s.close(); throw IOException("session cancelled during start") }
        session = s
        val l = try { ServerSocket(0) } catch (t: Throwable) { s.close(); throw t }
        listener = l
        latestSize = sizeMessage(s.width, s.height)
        s.onSession = { w, h ->
            synchronized(lock) {
                latestSize = sizeMessage(w, h)
                send(latestSize!!)
            }
        }
        thread("scr-video") { videoLoop(s) }
        thread("scr-devmsg") { deviceMessageLoop(s) }
        if (s.audio != null) thread("scr-audio") { audioLoop(s) }
        thread("scr-accept") { acceptLoop(l, s) }
        return ScreenSession.Ready(l.localPort, Base64.encodeToString(secret, Base64.NO_WRAP), s.width, s.height, s.codec)
    }

    private fun videoLoop(s: ScrcpyServerSession) {
        try {
            while (!ended.get()) {
                val (hdr, payload) = s.readPacket()
                val msg = ByteBuffer.allocate(1 + 8 + payload.size).put(KIND_VIDEO).putLong(hdr).put(payload).array()
                synchronized(lock) {
                    if (hdr and FLAG_CONFIG != 0L) latestConfig = msg
                    send(msg)
                }
            }
        } catch (e: Exception) {
            if (!ended.get()) Log.i(TAG, "[$sessionId] video stream ended: $e")
        }
        end()
    }

    private fun audioLoop(s: ScrcpyServerSession) {
        try {
            while (!ended.get()) {
                val (hdr, pcm) = s.readAudioPacket()
                val msg = ByteBuffer.allocate(1 + 8 + pcm.size).put(KIND_AUDIO).putLong(hdr).put(pcm).array()
                synchronized(lock) { send(msg) } // dropped when no viewer is attached: PCM needs no replay
            }
        } catch (e: Exception) {
            if (!ended.get()) Log.i(TAG, "[$sessionId] audio stream ended: $e")
        }
    }

    private fun deviceMessageLoop(s: ScrcpyServerSession) {
        val buf = ByteArray(8192)
        try {
            while (!ended.get()) {
                val n = s.readDeviceMessages(buf)
                if (n < 0) break
                val msg = ByteArray(1 + n).also { it[0] = KIND_DEVICE_MSG; System.arraycopy(buf, 0, it, 1, n) }
                synchronized(lock) { send(msg) }
            }
        } catch (_: Exception) {
        }
    }

    private fun acceptLoop(l: ServerSocket, s: ScrcpyServerSession) {
        val deadline = System.currentTimeMillis() + ATTACH_TIMEOUT_MS
        val authenticating = AtomicInteger(0)
        try {
            while (!ended.get() && !claimed.get()) {
                val remaining = deadline - System.currentTimeMillis()
                if (remaining <= 0) { Log.i(TAG, "[$sessionId] no viewer within ${ATTACH_TIMEOUT_MS}ms"); break }
                l.soTimeout = minOf(remaining, 1000L).toInt()
                val sock = try { l.accept() } catch (_: java.net.SocketTimeoutException) { continue }
                if (authenticating.incrementAndGet() > MAX_AUTHENTICATING) {
                    authenticating.decrementAndGet(); runCatching { sock.close() }; continue
                }
                thread("scr-auth") {
                    try { authenticateAndServe(sock, l, s) } finally { authenticating.decrementAndGet() }
                }
            }
        } catch (e: Exception) {
            if (!ended.get()) Log.i(TAG, "[$sessionId] accept loop ended: $e")
        }
        if (!claimed.get()) end() // nobody authenticated in time
    }

    private fun authenticateAndServe(sock: java.net.Socket, l: ServerSocket, s: ScrcpyServerSession) {
        val ws = try {
            sock.tcpNoDelay = true // interactive stream: never let Nagle hold back a small frame/ack
            sock.soTimeout = AUTH_TIMEOUT_MS
            WebSocketConnection.accept(sock)
        } catch (e: IOException) {
            Log.i(TAG, "[$sessionId] rejected non-WebSocket/failed handshake from ${sock.inetAddress}: $e")
            runCatching { sock.close() }; return
        }
        val hello = try {
            ws.readMessage()?.takeIf { !it.isText }?.let { cipher.open(it.data) }
        } catch (e: Exception) { null }
        val presented = hello?.takeIf { it.isNotEmpty() && it[0] == KIND_BINARY }?.copyOfRange(1, hello.size)
        if (presented == null || !MessageDigest.isEqual(presented, sessionId.toByteArray(Charsets.UTF_8))) {
            Log.i(TAG, "[$sessionId] viewer ${sock.inetAddress} failed authentication")
            runCatching { ws.close(1008) }; return
        }
        if (!claimed.compareAndSet(false, true)) { runCatching { ws.close(1008) }; return }
        sock.soTimeout = 0
        runCatching { l.close() } // one viewer per session
        try {
            attach(ws, s)
            controlLoop(ws, s)
        } catch (e: Exception) {
            if (!ended.get()) Log.i(TAG, "[$sessionId] control loop ended: $e")
        }
        end()
    }

    private fun attach(ws: WebSocketConnection, s: ScrcpyServerSession) {
        viewerAttached = true
        synchronized(lock) {
            sealed(ws, KIND_TEXT, (
                JSONObject().put("codec", s.codec).put("width", s.width).put("height", s.height)
                    .put("deviceName", s.deviceName)
                    .put("audio", s.audio?.let {
                        JSONObject().put("codec", it.codec).put("sampleRate", it.sampleRate)
                            .put("channels", it.channels).put("format", "s16le")
                    } ?: JSONObject.NULL)
                    .toString()).toByteArray(Charsets.UTF_8))
            latestSize?.let { sealed(ws, KIND_BINARY, it) }
            latestConfig?.let { sealed(ws, KIND_BINARY, it) }
            client = ws
        }
        s.writeControl(byteArrayOf(CONTROL_RESET_VIDEO)) // force a key frame for the late joiner
        Log.i(TAG, "[$sessionId] viewer attached")
    }

    private fun controlLoop(ws: WebSocketConnection, s: ScrcpyServerSession) {
        while (!ended.get()) {
            val m = ws.readMessage() ?: return
            if (m.isText) return // the sealed protocol is binary-only
            val plain = try { cipher.open(m.data) } catch (e: ScreenCipher.Failure) {
                Log.i(TAG, "[$sessionId] closing: ${e.message}"); return
            }
            if (plain.size > 1 && plain[0] == KIND_BINARY) s.writeControl(plain.copyOfRange(1, plain.size))
        }
    }

    /** Seals and writes one message. Caller holds [lock] so counter order matches wire order. */
    private fun sealed(ws: WebSocketConnection, kind: Byte, body: ByteArray) {
        ws.sendBinary(cipher.seal(byteArrayOf(kind) + body))
    }

    /** Caller holds [lock]. A failed write means the viewer is gone — end the session. */
    private fun send(msg: ByteArray) {
        val ws = client ?: return
        try { sealed(ws, KIND_BINARY, msg) } catch (_: IOException) { Thread { end() }.start() }
    }

    /** Idempotent teardown: closes viewer, listener, and both shell-UID processes. */
    fun end() {
        if (!ended.compareAndSet(false, true)) return
        synchronized(lock) { runCatching { client?.close(1001) } }
        runCatching { listener?.close() }
        runCatching { session?.close() }
        Log.i(TAG, "[$sessionId] ended")
        // A session someone was actually watching leaves the screen lit; put it to sleep. Sessions that
        // never got a viewer (failed start, attach timeout) must not touch the screen.
        if (viewerAttached) ScreenOff.sleep()
        onEnded()
    }

    override fun close() = end()

    private fun sizeMessage(w: Int, h: Int): ByteArray =
        ByteBuffer.allocate(9).put(KIND_SIZE).putInt(w).putInt(h).array()

    private fun thread(name: String, body: () -> Unit) =
        Thread(body, name).apply { isDaemon = true }.start()

    companion object {
        private const val TAG = "ScreenBridge"
        const val KIND_VIDEO: Byte = 0x00
        const val KIND_SIZE: Byte = 0x01
        const val KIND_DEVICE_MSG: Byte = 0x02
        const val KIND_AUDIO: Byte = 0x03
        private const val FLAG_CONFIG = 1L shl 62
        private const val CONTROL_RESET_VIDEO: Byte = 17
        const val ATTACH_TIMEOUT_MS = 30_000L
        private const val AUTH_TIMEOUT_MS = 10_000
        private const val MAX_AUTHENTICATING = 4
        private const val KIND_TEXT: Byte = 0x00
        private const val KIND_BINARY: Byte = 0x01
    }
}
