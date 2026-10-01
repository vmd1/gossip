package dev.vmd1.gossip.features.screenmirror

import android.content.Context
import android.util.Base64
import android.util.Log
import org.json.JSONObject
import java.io.Closeable
import java.io.IOException
import java.net.ServerSocket
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.atomic.AtomicBoolean

/** What [ScreenMirrorState] needs from a session — an interface so its start/stop/idempotency
 *  logic is unit-testable without Shizuku or a device. */
interface ScreenSession : Closeable {
    data class Ready(val port: Int, val token: String, val width: Int, val height: Int, val codec: String)
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
 * **Viewer wire format** (WebSocket, port from `screen.ready`):
 * - viewer → bridge, first message: the session `token` (text). Anything else closes with 1008.
 * - bridge → viewer, text: `{"codec","width","height","deviceName"}` once, right after auth.
 * - bridge → viewer, binary, first byte = kind: `0x00` video packet (`u64 BE pts/flags`, then
 *   Annex-B H.264; flags bit 62 = config/SPS+PPS, bit 61 = key frame), `0x01` size change
 *   (`u32 BE width`, `u32 BE height`), `0x02` raw scrcpy device-message bytes (control socket).
 * - viewer → bridge, binary after auth: raw scrcpy control messages (inject touch/key/scroll...),
 *   forwarded verbatim to the server's control socket.
 * On attach the bridge replays the cached size + config packet and sends scrcpy `RESET_VIDEO`
 * so a viewer that attaches late (the server starts at `screen.start`, before the viewer
 * connects) gets a key frame immediately even on a static screen.
 *
 * **Auth**: possession of the random 256-bit token, delivered only inside the Noise-encrypted
 * mesh (`screen.ready`). Video itself is *not* encrypted on the WebSocket — see README.
 */
class ScreenBridge(
    private val context: Context,
    override val sessionId: String,
    private val options: ScrcpyServerSession.Options,
    private val onEnded: () -> Unit,
) : ScreenSession {

    private val token: String = ByteArray(32).also { SecureRandom().nextBytes(it) }
        .let { Base64.encodeToString(it, Base64.NO_WRAP or Base64.URL_SAFE or Base64.NO_PADDING) }
    private val ended = AtomicBoolean(false)
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
        thread("scr-accept") { acceptLoop(l, s) }
        return ScreenSession.Ready(l.localPort, token, s.width, s.height, s.codec)
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
        try {
            while (!ended.get()) {
                val remaining = deadline - System.currentTimeMillis()
                if (remaining <= 0) { Log.i(TAG, "[$sessionId] no viewer within ${ATTACH_TIMEOUT_MS}ms"); break }
                l.soTimeout = remaining.toInt()
                val sock = try { l.accept() } catch (_: java.net.SocketTimeoutException) { continue }
                val ws = try {
                    sock.tcpNoDelay = true // interactive stream: never let Nagle hold back a small frame/ack
                    sock.soTimeout = AUTH_TIMEOUT_MS
                    WebSocketConnection.accept(sock)
                } catch (e: IOException) {
                    Log.i(TAG, "[$sessionId] rejected non-WebSocket/failed handshake from ${sock.inetAddress}: $e")
                    runCatching { sock.close() }; continue
                }
                val first = try { ws.readMessage() } catch (e: IOException) {
                    Log.i(TAG, "[$sessionId] viewer ${sock.inetAddress} dropped before sending a token: $e"); null
                }
                val presented = first?.data?.toString(Charsets.UTF_8)?.toByteArray(Charsets.UTF_8) ?: ByteArray(0)
                if (first == null || !MessageDigest.isEqual(presented, token.toByteArray(Charsets.UTF_8))) {
                    Log.i(TAG, "[$sessionId] viewer ${sock.inetAddress} sent no/incorrect token (first=${first?.data?.size} bytes)")
                    ws.close(1008); continue
                }
                sock.soTimeout = 0
                runCatching { l.close() } // one viewer per session
                attach(ws, s)
                controlLoop(ws, s)
                break
            }
        } catch (e: Exception) {
            if (!ended.get()) Log.i(TAG, "[$sessionId] accept/control loop ended: $e")
        }
        end()
    }

    private fun attach(ws: WebSocketConnection, s: ScrcpyServerSession) {
        synchronized(lock) {
            ws.sendText(
                JSONObject().put("codec", s.codec).put("width", s.width).put("height", s.height)
                    .put("deviceName", s.deviceName).toString()
            )
            latestSize?.let { ws.sendBinary(it) }
            latestConfig?.let { ws.sendBinary(it) }
            client = ws
        }
        s.writeControl(byteArrayOf(CONTROL_RESET_VIDEO)) // force a key frame for the late joiner
        Log.i(TAG, "[$sessionId] viewer attached")
    }

    private fun controlLoop(ws: WebSocketConnection, s: ScrcpyServerSession) {
        while (!ended.get()) {
            val m = ws.readMessage() ?: return
            if (!m.isText && m.data.isNotEmpty()) s.writeControl(m.data)
        }
    }

    /** Caller holds [lock]. A failed write means the viewer is gone — end the session. */
    private fun send(msg: ByteArray) {
        val ws = client ?: return
        try { ws.sendBinary(msg) } catch (_: IOException) { Thread { end() }.start() }
    }

    /** Idempotent teardown: closes viewer, listener, and both shell-UID processes. */
    fun end() {
        if (!ended.compareAndSet(false, true)) return
        synchronized(lock) { runCatching { client?.close(1001) } }
        runCatching { listener?.close() }
        runCatching { session?.close() }
        Log.i(TAG, "[$sessionId] ended")
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
        private const val FLAG_CONFIG = 1L shl 62
        private const val CONTROL_RESET_VIDEO: Byte = 17
        const val ATTACH_TIMEOUT_MS = 30_000L
        private const val AUTH_TIMEOUT_MS = 10_000
    }
}
