package dev.vmd1.gossip.features.universalcontrol

import android.content.Context
import android.hardware.display.DisplayManager
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import dev.vmd1.gossip.util.Log
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
    private val cursorLocator: CursorLocator = CursorLocator(),
    /** How long the virtual devices outlive a `leave`, so crossing back soon after is instant. */
    private val deviceGraceMs: Long = DEVICE_GRACE_MS,
    /** Whether the screen is on; the cursor arriving on a dark screen wakes it. */
    private val isScreenOn: () -> Boolean = { (context.getSystemService(Context.POWER_SERVICE) as PowerManager).isInteractive },
) : ControlSessionHandle {
    private val cipher = ControlCipher(secret, sessionId, deviceSide = true)
    private val sendLock = Any()
    private val ended = AtomicBoolean(false)
    private val claimed = AtomicBoolean(false)
    private var server: ScrcpyServerSession? = null
    private var listener: ServerSocket? = null
    private var ws: WebSocketConnection? = null
    private var backend: InputBackend? = null
    private var lastInfo: ControlDisplayInfo? = null
    private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "ctl-input").apply { isDaemon = true } }
    private val enterLock = Any()
    private var pendingEnters = 0                       // enterLock
    private var droppedMoves = 0L                       // enterLock
    @Volatile private var appliedBase = 0L              // moves dropped during the last enter, counted as applied
    private val grace = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "ctl-grace").apply { isDaemon = true } }
    private var graceTask: java.util.concurrent.ScheduledFuture<*>? = null
    private val cursorExec = Executors.newSingleThreadExecutor { r -> Thread(r, "ctl-cursor").apply { isDaemon = true } }
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
        Log.i(TAG, "[$sessionId] listening on port ${l.localPort} (display ${info.width}x${info.height} rotation ${info.rotation})")
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

    /** Each accepted connection authenticates on its own thread, so a stalled or junk connection can't hold up
     *  the real Mac; the first to send a valid hello wins and the listener closes. */
    private fun acceptLoop(l: ServerSocket) {
        val authenticating = java.util.concurrent.atomic.AtomicInteger(0)
        try {
            val deadline = System.currentTimeMillis() + ATTACH_TIMEOUT_MS
            while (!ended.get() && !claimed.get()) {
                val remaining = deadline - System.currentTimeMillis()
                if (remaining <= 0) { Log.i(TAG, "[$sessionId] no Mac within ${ATTACH_TIMEOUT_MS}ms"); break }
                l.soTimeout = minOf(remaining, 1000L).toInt()
                val sock = try { l.accept() } catch (_: java.net.SocketTimeoutException) { continue }
                if (authenticating.incrementAndGet() > MAX_AUTHENTICATING) {
                    authenticating.decrementAndGet(); runCatching { sock.close() }; continue
                }
                thread("ctl-auth") {
                    try { authenticateAndServe(sock, l) } finally { authenticating.decrementAndGet() }
                }
            }
        } catch (e: Exception) {
            if (!ended.get()) Log.i(TAG, "[$sessionId] accept loop ended: $e")
        }
        if (!claimed.get()) end() // nobody authenticated in time
    }

    private fun authenticateAndServe(sock: java.net.Socket, l: ServerSocket) {
        val conn = try {
            sock.tcpNoDelay = true // pointer motion: never let Nagle hold a small frame back
            sock.soTimeout = AUTH_TIMEOUT_MS
            WebSocketConnection.accept(sock)
        } catch (e: IOException) {
            Log.i(TAG, "[$sessionId] rejected non-WebSocket client: $e"); runCatching { sock.close() }; return
        }
        val hello = try { conn.readMessage() } catch (e: IOException) { null }
        // The cipher isn't thread-safe and several connections may be authenticating at once.
        val frame = try { hello?.takeIf { !it.isText }?.let { synchronized(cipher) { cipher.open(it.data) } } } catch (_: ControlCipher.Failure) { null }
        if (frame !is ControlFrame.Hello || !constantTimeEquals(frame.sessionId, sessionId)) {
            Log.i(TAG, "[$sessionId] client failed the encrypted hello"); runCatching { conn.close(1008) }; return
        }
        if (!claimed.compareAndSet(false, true)) { runCatching { conn.close(1008) }; return }
        try {
            sock.soTimeout = IDLE_TIMEOUT_MS // the Mac pings every few seconds; silence means it's gone
            runCatching { l.close() } // one Mac per session
            ws = conn
            sendFrame(ControlFrame.HelloAck(currentDisplayInfo().also { lastInfo = it }))
            Log.i(TAG, "[$sessionId] Mac attached")
            frameLoop(conn)
        } catch (e: Exception) {
            if (!ended.get()) Log.i(TAG, "[$sessionId] frame loop ended: $e")
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
            is ControlFrame.Hello, is ControlFrame.HelloAck, is ControlFrame.DisplayInfo, is ControlFrame.Error, ControlFrame.Pong, is ControlFrame.CursorPos -> Unit
            // Input is applied in order on one worker, so a slow `enter` (device creation) never reorders later frames.
            is ControlFrame.Enter -> {
                // The cursor arriving on a dark screen wakes it (queued ahead of the placement below).
                if (!runCatching { isScreenOn() }.getOrDefault(true)) run { it.wake() }
                graceTask?.cancel(false)
                dev.vmd1.gossip.features.remote.RemoteActivity.setRemoteInput(true)
                synchronized(enterLock) { pendingEnters++; droppedMoves = 0 }
                run {
                    try {
                        it.enter(frame.edge, frame.position, currentDisplayInfo())
                        // The pointer is stationary at an exactly-known spot right now: measure the cursor image's hotspot
                        // offset once, here on the input worker so no queued move shifts the pointer during the read.
                        if (!cursorLocator.calibrated) it.entryPoint?.let { p -> cursorLocator.calibrate(p) }
                    } finally {
                        // Even if placement failed: never leave the bridge dropping motion.
                        synchronized(enterLock) { appliedBase = droppedMoves; pendingEnters-- }
                    }
                }
            }
            is ControlFrame.CursorQuery -> answerCursorQuery(frame.token)
            ControlFrame.Leave -> {
                dev.vmd1.gossip.features.remote.RemoteActivity.setRemoteInput(false)
                run { it.leave() }
                // Keep the devices a while: re-entering soon skips their (slow) creation. They are destroyed later
                // unless the cursor came back, so the cursor and the hardware-keyboard state don't linger.
                graceTask?.cancel(false)
                graceTask = runCatching {
                    grace.schedule({ run { it.destroyDevices() } }, deviceGraceMs, java.util.concurrent.TimeUnit.MILLISECONDS)
                }.getOrNull()
            }
            is ControlFrame.MouseMove -> {
                // Motion that arrives while the cursor is still being placed would be applied in one burst the moment
                // the placement finishes (a visible jump). Drop it instead: the Mac's model is corrected by the
                // closed-loop position reports. Dropped moves still count as applied so those reports stay aligned.
                val drop = synchronized(enterLock) { if (pendingEnters > 0) { droppedMoves++; true } else false }
                if (!drop) run { it.mouseMove(frame.dx, frame.dy) }
            }
            is ControlFrame.Buttons -> run { it.buttons(frame.mask) }
            is ControlFrame.Scroll -> run { it.scroll(frame.dx, frame.dy) }
            is ControlFrame.Key -> run { it.key(frame.usage, frame.down, frame.modifiers) }
            is ControlFrame.Text -> run { it.text(frame.text) }
            is ControlFrame.Action -> run { it.action(frame.action) }
        }
    }

    /** Reads the real cursor off the input path (a read takes ~100 ms) and answers the Mac. No answer if unreadable. */
    private fun answerCursorQuery(token: Int) {
        val b = backend ?: return
        try {
            cursorExec.execute {
                if (ended.get()) return@execute
                val before = b.movesApplied + appliedBase
                val pos = cursorLocator.position() ?: return@execute
                val after = b.movesApplied + appliedBase
                // The read lands somewhere inside the window, so report the middle of it.
                sendFrame(ControlFrame.CursorPos(token, Math.round(pos.first), Math.round(pos.second), before + (after - before) / 2))
            }
        } catch (_: java.util.concurrent.RejectedExecutionException) {}
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
        dev.vmd1.gossip.features.remote.RemoteActivity.setRemoteInput(false)
        cursorExec.shutdownNow()
        grace.shutdownNow()
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
        const val DEVICE_GRACE_MS = 8_000L
        private const val AUTH_TIMEOUT_MS = 10_000
        private const val MAX_AUTHENTICATING = 4
        private const val IDLE_TIMEOUT_MS = 20_000
    }
}
