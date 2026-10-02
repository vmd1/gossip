package dev.vmd1.gossip.features.universalcontrol

import android.content.Context
import android.hardware.display.DisplayManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import dev.vmd1.gossip.features.screenmirror.ScrcpyServerSession
import java.io.Closeable
import java.io.IOException
import java.net.ServerSocket
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import dev.vmd1.gossip.features.screenmirror.WebSocketConnection

/** What [ControlSessionState] needs from a session, so its start/end/idempotency logic is testable without a device. */
interface ControlSessionHandle : Closeable {
    data class Ready(val port: Int, val info: ControlDisplayInfo, val backend: String)
    val sessionId: String
    /** Blocking; throws if the input backend can't be started. */
    fun start(): Ready
}

/**
 * One Universal Control session on the device: a control-only scrcpy server (no video, no audio, no mirror
 * window, never touches the screen) plus an encrypted WebSocket listener the Mac dials. See `ControlProtocol.kt`
 * for the frame format and `schema/message-types.md` (`control.*`) for the mesh half.
 *
 * Auth: the first WebSocket message must be an encrypted `hello` carrying this session id, which proves the
 * peer holds the `secret` delivered inside the Noise-encrypted mesh. Everything after rides the same cipher,
 * with strictly increasing counters, so a replayed or duplicated frame is dropped (the data channel does not
 * share the mesh's duplicate-delivery risk). One Mac connection per session; when it drops the session ends
 * and the Mac negotiates a fresh one (fresh key), because counter nonces must never be reused under a key.
 */
class ControlBridge(
    private val context: Context,
    override val sessionId: String,
    secret: ByteArray,
    private val onEnded: () -> Unit,
    private val backendFactory: (write: (ByteArray) -> Unit) -> InputBackend = { UhidInputBackend(it) },
    private val serverFactory: (Context) -> ScrcpyServerSession = { ScrcpyServerSession.openControlOnly(it) },
) : ControlSessionHandle {
    private val cipher = ControlCipher(secret, sessionId, deviceSide = true)
    private val sendLock = Any()
    private val ended = AtomicBoolean(false)
    private var server: ScrcpyServerSession? = null
    private var listener: ServerSocket? = null
    private var ws: WebSocketConnection? = null
    private var backend: InputBackend? = null
    private var lastInfo: ControlDisplayInfo? = null
    private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "ctl-input").apply { isDaemon = true } }
    private val displayManager = context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
    private val mainHandler = Handler(Looper.getMainLooper())
    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) {}
        override fun onDisplayRemoved(displayId: Int) {}
        override fun onDisplayChanged(displayId: Int) {
            if (displayId != android.view.Display.DEFAULT_DISPLAY) return
            val info = currentDisplayInfo()
            if (info != lastInfo) { lastInfo = info; sendFrame(ControlFrame.DisplayInfo(info)) }
        }
    }

    override fun start(): ControlSessionHandle.Ready {
        val s = serverFactory(context)
        if (ended.get()) { s.close(); throw IOException("session cancelled during start") }
        server = s
        val l = try { ServerSocket(0) } catch (t: Throwable) { s.close(); throw t }
        listener = l
        backend = backendFactory { bytes -> runCatching { s.writeControl(bytes) }.onFailure { end() } }
        val info = currentDisplayInfo().also { lastInfo = it }
        mainHandler.post { displayManager.registerDisplayListener(displayListener, mainHandler) }
        thread("ctl-accept") { acceptLoop(l) }
        thread("ctl-devmsg") { drainDeviceMessages(s) }
        return ControlSessionHandle.Ready(l.localPort, info, "uhid")
    }

    private fun currentDisplayInfo(): ControlDisplayInfo {
        val d = displayManager.getDisplay(android.view.Display.DEFAULT_DISPLAY)
        val size = android.graphics.Point().also { @Suppress("DEPRECATION") d.getRealSize(it) } // rotation-applied
        return ControlDisplayInfo(size.x, size.y, d.rotation, backend?.kind ?: ControlBackendKind.UHID)
    }

    private fun drainDeviceMessages(s: ScrcpyServerSession) {
        val buf = ByteArray(4096)
        try { while (s.readDeviceMessages(buf) >= 0) Unit } catch (_: Exception) {}
        if (!ended.get()) { Log.i(TAG, "[$sessionId] scrcpy server went away"); end() } // e.g. Shizuku died
    }

    private fun acceptLoop(l: ServerSocket) {
        try {
            val deadline = System.currentTimeMillis() + ATTACH_TIMEOUT_MS
            while (!ended.get()) {
                val remaining = deadline - System.currentTimeMillis()
                if (remaining <= 0) { Log.i(TAG, "[$sessionId] no Mac within ${ATTACH_TIMEOUT_MS}ms"); break }
                l.soTimeout = remaining.toInt()
                val sock = try { l.accept() } catch (_: java.net.SocketTimeoutException) { continue }
                val conn = try {
                    sock.tcpNoDelay = true // pointer motion: never let Nagle hold a small frame back
                    sock.soTimeout = AUTH_TIMEOUT_MS
                    WebSocketConnection.accept(sock)
                } catch (e: IOException) {
                    Log.i(TAG, "[$sessionId] rejected non-WebSocket client: $e"); runCatching { sock.close() }; continue
                }
                val hello = try { conn.readMessage() } catch (e: IOException) { null }
                val frame = try { hello?.takeIf { !it.isText }?.let { cipher.open(it.data) } } catch (_: ControlCipher.Failure) { null }
                if (frame !is ControlFrame.Hello || !constantTimeEquals(frame.sessionId, sessionId)) {
                    Log.i(TAG, "[$sessionId] client failed the encrypted hello"); conn.close(1008); continue
                }
                sock.soTimeout = IDLE_TIMEOUT_MS // the Mac pings every few seconds; silence means it's gone
                runCatching { l.close() } // one Mac per session
                ws = conn
                sendFrame(ControlFrame.HelloAck(currentDisplayInfo().also { lastInfo = it }))
                Log.i(TAG, "[$sessionId] Mac attached")
                frameLoop(conn)
                break
            }
        } catch (e: Exception) {
            if (!ended.get()) Log.i(TAG, "[$sessionId] accept/frame loop ended: $e")
        }
        end()
    }

    private fun frameLoop(conn: WebSocketConnection) {
        while (!ended.get()) {
            val m = conn.readMessage() ?: return
            if (m.isText) continue
            val frame = try {
                cipher.open(m.data)
            } catch (f: ControlCipher.Failure) {
                if (f.replayed) continue // a duplicated frame is simply dropped
                Log.w(TAG, "[$sessionId] bad frame (${f.message}); closing"); conn.close(1008); return
            } ?: continue
            handle(frame)
        }
    }

    private fun handle(frame: ControlFrame) {
        when (frame) {
            ControlFrame.Ping -> sendFrame(ControlFrame.Pong)
            is ControlFrame.Hello, is ControlFrame.HelloAck, is ControlFrame.DisplayInfo, is ControlFrame.Error, ControlFrame.Pong -> Unit
            // Input is applied in order on one worker, so a slow `enter` (device creation) never reorders later frames.
            is ControlFrame.Enter -> run { it.enter(frame.edge, frame.position, currentDisplayInfo()) }
            ControlFrame.Leave -> run { it.leave() }
            is ControlFrame.MouseMove -> run { it.mouseMove(frame.dx, frame.dy) }
            is ControlFrame.Buttons -> run { it.buttons(frame.mask) }
            is ControlFrame.Scroll -> run { it.scroll(frame.dx, frame.dy) }
            is ControlFrame.Key -> run { it.key(frame.usage, frame.down, frame.modifiers) }
            is ControlFrame.Text -> run { it.text(frame.text) }
        }
    }

    private fun run(block: (InputBackend) -> Unit) {
        val b = backend ?: return
        try {
            worker.execute { if (!ended.get()) runCatching { block(b) }.onFailure { Log.w(TAG, "[$sessionId] input failed", it) } }
        } catch (_: java.util.concurrent.RejectedExecutionException) {}
    }

    private fun sendFrame(frame: ControlFrame) {
        val conn = ws ?: return
        try {
            synchronized(sendLock) { conn.sendBinary(cipher.seal(frame)) }
        } catch (_: IOException) { Thread { end() }.start() }
    }

    /** Idempotent teardown: removes the virtual devices, closes the Mac, the listener and the scrcpy server. */
    fun end() {
        if (!ended.compareAndSet(false, true)) return
        runCatching { worker.execute { runCatching { backend?.close() } ; worker.shutdown() } }
        mainHandler.post { runCatching { displayManager.unregisterDisplayListener(displayListener) } }
        runCatching { ws?.close(1001) }
        runCatching { listener?.close() }
        // Give the worker a moment to flush the UHID_DESTROY messages before the server (and its socket) go away.
        Thread({
            runCatching { worker.awaitTermination(1, java.util.concurrent.TimeUnit.SECONDS) }
            runCatching { server?.close() }
            Log.i(TAG, "[$sessionId] ended")
            onEnded()
        }, "ctl-teardown").apply { isDaemon = true }.start()
    }

    override fun close() = end()

    private fun thread(name: String, body: () -> Unit) = Thread(body, name).apply { isDaemon = true }.start()

    companion object {
        private const val TAG = "ControlBridge"
        const val ATTACH_TIMEOUT_MS = 30_000L
        private const val AUTH_TIMEOUT_MS = 10_000
        private const val IDLE_TIMEOUT_MS = 20_000
    }
}
