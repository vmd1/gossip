package dev.vmd1.gossip.features.screenmirror

import android.content.Context
import android.util.Log
import java.io.Closeable
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.PipedInputStream
import java.io.PipedOutputStream
import java.security.SecureRandom

/**
 * One running instance of the bundled upstream scrcpy server (Genymobile/scrcpy v[SCRCPY_VERSION],
 * Apache 2.0, `assets/scrcpy-server-v4.1.jar`) launched at shell UID through Shizuku's
 * `newProcess`, plus a second shell-UID process ([ShellRelay]) that connects to the server's
 * abstract sockets on this app's behalf and multiplexes them over Shizuku's stdio.
 *
 * Launch is scrcpy's own: `CLASSPATH=<jar> app_process / com.genymobile.scrcpy.Server <version>
 * key=value...` with `tunnel_forward=true` (server listens on abstract socket `scrcpy_<scid>`).
 * The app can't connect to that socket itself — SELinux denies untrusted_app→shell `connectto`
 * (and the reverse), see `android/screen-server/README.md` — hence the relay.
 */
class ScrcpyServerSession private constructor(
    private val serverProcess: Process,
    private val relayProcess: Process,
    val deviceName: String,
    val codec: String,
    width: Int,
    height: Int,
    private val videoIn: DataInputStream,
    private val deviceMsgIn: InputStream,
    private val audioIn: DataInputStream?,
    /** Audio format when the server is capturing audio, else `null` (disabled, unsupported or errored). */
    val audio: AudioFormat?,
) : Closeable {
    /** Raw PCM as produced by scrcpy's `audio_codec=raw`: signed 16-bit little-endian, interleaved. */
    data class AudioFormat(val codec: String = "raw", val sampleRate: Int = 48_000, val channels: Int = 2)

    private val relayOut = DataOutputStream(relayProcess.outputStream.buffered(8 * 1024))
    @Volatile private var closed = false

    /** Invoked from [readPacket]'s thread whenever a session packet changes the encoded size. */
    @Volatile var onSession: ((width: Int, height: Int) -> Unit)? = null

    /** Current encoded size; updated whenever the server sends a new session packet (rotation etc.). */
    @Volatile var width: Int = width; private set
    @Volatile var height: Int = height; private set

    /**
     * Reads one video packet: returns (ptsAndFlags, payload). Blocks. Throws on EOF.
     * scrcpy 4.x interleaves 12-byte *session packets* (u32 `0x80000000` marker, u32 width,
     * u32 height) with media packets (u64 pts/flags, u32 size); a media packet's pts/flags
     * never has bit 63 set, so the first u32 tells them apart. Session packets are absorbed here.
     */
    fun readPacket(): Pair<Long, ByteArray> {
        var first = videoIn.readInt()
        while (first < 0) {
            width = videoIn.readInt(); height = videoIn.readInt()
            onSession?.invoke(width, height)
            first = videoIn.readInt()
        }
        val pts = (first.toLong() shl 32) or (videoIn.readInt().toLong() and 0xffffffffL)
        val size = videoIn.readInt()
        require(size in 0..MAX_PACKET) { "implausible video packet size $size" }
        val buf = ByteArray(size)
        videoIn.readFully(buf)
        return pts to buf
    }

    /** Reads one audio packet (ptsAndFlags, PCM payload). Blocks. Only valid when [audio] != null. */
    fun readAudioPacket(): Pair<Long, ByteArray> {
        val input = checkNotNull(audioIn) { "audio not enabled" }
        val pts = input.readLong()
        val size = input.readInt()
        require(size in 0..MAX_PACKET) { "implausible audio packet size $size" }
        val buf = ByteArray(size)
        input.readFully(buf)
        return pts to buf
    }

    /** Raw bytes the scrcpy server sends on its control socket (clipboard etc.). Blocks. */
    fun readDeviceMessages(buf: ByteArray): Int = deviceMsgIn.read(buf)

    /** Writes already-framed scrcpy control message bytes to the server's control socket. */
    fun writeControl(bytes: ByteArray) {
        synchronized(relayOut) {
            relayOut.writeByte(ShellRelay.CONTROL)
            relayOut.writeInt(bytes.size)
            relayOut.write(bytes)
            relayOut.flush()
        }
    }

    val isClosed: Boolean get() = closed

    override fun close() {
        if (closed) return
        closed = true
        // Closing the relay's stdin makes it exit and close its sockets; the server exits when
        // its sockets close. destroy() is the belt-and-braces path for a wedged process.
        runCatching { relayProcess.outputStream.close() }
        runCatching { relayProcess.destroy() }
        runCatching { serverProcess.destroy() }
    }

    data class Options(
        val maxSize: Int = 1280,
        val videoBitRate: Int = 4_000_000,
        val maxFps: Int = 30,
        val audio: Boolean = false,
    )

    companion object {
        private const val TAG = "ScrcpyServerSession"
        const val SCRCPY_VERSION = "4.1"
        private const val ASSET = "scrcpy-server-v4.1.jar"
        private const val REMOTE_JAR = "/data/local/tmp/gossip-scrcpy-server.jar"
        private const val MAX_PACKET = 16 * 1024 * 1024
        private const val DEVICE_NAME_LEN = 64
        private const val PIPE_SIZE = 1 shl 20
        private const val AUDIO_ID_RAW = 0x00726177 // "\0raw"

        /**
         * Pushes the jar (streamed into a shell-UID `cat > file` — no storage permission
         * needed, and `/data/local/tmp` is where shell can read it), launches the server and
         * the relay, and reads the stream header. Blocking; call off the main thread.
         */
        fun open(context: Context, options: Options = Options()): ScrcpyServerSession {
            pushJar(context)
            val scid = "%08x".format(SecureRandom().nextInt() and 0x7fffffff)
            val socketName = "scrcpy_$scid"
            val serverCmd = "CLASSPATH=$REMOTE_JAR exec app_process / com.genymobile.scrcpy.Server " +
                "$SCRCPY_VERSION scid=$scid log_level=info tunnel_forward=true " +
                (if (options.audio) "audio=true audio_codec=raw " else "audio=false ") +
                "control=true cleanup=false max_size=${options.maxSize} " +
                "video_bit_rate=${options.videoBitRate} max_fps=${options.maxFps}"
            val relayCmd = "CLASSPATH=${context.applicationInfo.sourceDir} exec app_process / " +
                "${ShellRelay::class.java.name} $socketName ${if (options.audio) 1 else 0}"
            val server = ShizukuShell.exec("sh", "-c", serverCmd)
            drainLogs(server, "server")
            val relay = ShizukuShell.exec("sh", "-c", relayCmd)
            drainStderr(relay, "relay")
            try {
                // Demux relay stdout into video / device-message pipes.
                val videoPipeOut = PipedOutputStream()
                val videoPipeIn = PipedInputStream(videoPipeOut, PIPE_SIZE)
                val devPipeOut = PipedOutputStream()
                val devPipeIn = PipedInputStream(devPipeOut, PIPE_SIZE)
                val audioPipeOut = PipedOutputStream()
                val audioPipeIn = PipedInputStream(audioPipeOut, PIPE_SIZE)
                Thread({
                    val input = DataInputStream(relay.inputStream.buffered(64 * 1024))
                    try {
                        while (true) {
                            val channel = input.read()
                            if (channel < 0) break
                            val len = input.readInt()
                            val buf = ByteArray(len)
                            input.readFully(buf)
                            when (channel) {
                                // flush() is load-bearing: PipedInputStream readers that have caught up
                                // poll with a 1 s wait unless the writer flushes (which notifies them) —
                                // without it, frames stalled for up to a second after an idle moment.
                                ShellRelay.VIDEO -> videoPipeOut.write(buf).also { videoPipeOut.flush() }
                                ShellRelay.DEVICE_MSG -> devPipeOut.write(buf).also { devPipeOut.flush() }
                                ShellRelay.AUDIO -> audioPipeOut.write(buf).also { audioPipeOut.flush() }
                            }
                        }
                    } catch (_: IOException) {
                    } finally {
                        runCatching { videoPipeOut.close() }
                        runCatching { devPipeOut.close() }
                        runCatching { audioPipeOut.close() }
                    }
                }, "scrcpy-demux").apply { isDaemon = true }.start()

                val input = DataInputStream(videoPipeIn.buffered(64 * 1024))
                val nameBytes = ByteArray(DEVICE_NAME_LEN).also { input.readFully(it) }
                val name = String(nameBytes, Charsets.UTF_8).trimEnd('\u0000')
                val codecId = input.readInt()
                val marker = input.readInt()
                check(marker < 0) { "expected scrcpy session packet after codec id, got 0x${marker.toString(16)}" }
                val w = input.readInt()
                val h = input.readInt()
                val codec = String(
                    byteArrayOf((codecId shr 24).toByte(), (codecId shr 16).toByte(), (codecId shr 8).toByte(), codecId.toByte())
                )
                Log.i(TAG, "scrcpy stream open: device='$name' codec=$codec ${w}x$h")
                var audioInput: DataInputStream? = null
                var audioFormat: AudioFormat? = null
                if (options.audio) {
                    // First 4 bytes of the audio stream: codec id ("raw\0"), or 0 = audio disabled
                    // server-side, 1 = audio configuration error (both leave us video-only).
                    audioInput = DataInputStream(audioPipeIn.buffered(64 * 1024))
                    val audioId = audioInput.readInt()
                    if (audioId == AUDIO_ID_RAW) audioFormat = AudioFormat()
                    else Log.w(TAG, "scrcpy audio unavailable (codec id 0x${audioId.toString(16)}); continuing video-only")
                }
                return ScrcpyServerSession(server, relay, name, codec, w, h, input, devPipeIn, audioInput, audioFormat)
            } catch (t: Throwable) {
                runCatching { relay.destroy() }
                runCatching { server.destroy() }
                throw t
            }
        }

        private fun pushJar(context: Context) {
            val p = ShizukuShell.exec("sh", "-c", "cat > $REMOTE_JAR.tmp && chmod 644 $REMOTE_JAR.tmp && mv -f $REMOTE_JAR.tmp $REMOTE_JAR")
            p.outputStream.use { out -> context.assets.open(ASSET).use { it.copyTo(out) } }
            val err = p.errorStream.bufferedReader().readText()
            val code = p.waitFor()
            if (code != 0) throw IOException("pushing scrcpy jar failed (exit $code): $err")
        }

        private fun drainLogs(process: Process, tag: String) {
            drainStderr(process, tag)
            Thread({
                runCatching { process.inputStream.bufferedReader().forEachLine { Log.i(TAG, "[$tag] $it") } }
            }, "scrcpy-log-$tag").apply { isDaemon = true }.start()
        }

        private fun drainStderr(process: Process, tag: String) {
            Thread({
                runCatching { process.errorStream.bufferedReader().forEachLine { Log.i(TAG, "[$tag] $it") } }
            }, "scrcpy-err-$tag").apply { isDaemon = true }.start()
        }
    }
}
