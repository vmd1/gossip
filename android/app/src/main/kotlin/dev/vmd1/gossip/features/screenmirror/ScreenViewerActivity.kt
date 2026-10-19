package dev.vmd1.gossip.features.screenmirror

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.graphics.Color
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Bundle
import android.view.Gravity
import android.view.MotionEvent
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import dev.vmd1.gossip.crypto.IdentityKeyStore
import dev.vmd1.gossip.features.settings.Feature
import dev.vmd1.gossip.features.settings.FeatureSettings
import dev.vmd1.gossip.transport.TransportManagerHolder
import dev.vmd1.gossip.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import java.nio.ByteBuffer

private const val TAG = "ScreenViewer"

/**
 * Shows another paired Android device's screen (Android → Android mirroring): H.264 decoded with [MediaCodec] onto a
 * [SurfaceView], PCM audio through an [AudioTrack], touch and Back/Home/Recents sent back as scrcpy control messages.
 * The negotiation and the encrypted transport are [ScreenViewerSession]; the device being mirrored needs Shizuku, this
 * viewer does not.
 */
class ScreenViewerActivity : Activity(), ScreenViewerSession.Listener, SurfaceHolder.Callback {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var session: ScreenViewerSession? = null
    private lateinit var surfaceView: SurfaceView
    private lateinit var frame: FrameLayout
    private lateinit var status: TextView

    private val lock = Any()
    private var surface: Surface? = null
    private var codec: MediaCodec? = null
    private var videoWidth = 0
    private var videoHeight = 0
    private var pendingConfig: ByteArray? = null
    private var audioTrack: AudioTrack? = null
    private var finishedByUs = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR
        val deviceId = intent.getStringExtra(EXTRA_DEVICE_ID)
        val deviceName = intent.getStringExtra(EXTRA_DEVICE_NAME) ?: "device"
        val transport = TransportManagerHolder.instance

        surfaceView = SurfaceView(this).apply { holder.addCallback(this@ScreenViewerActivity) }
        status = TextView(this).apply { setTextColor(Color.WHITE); textSize = 16f; text = "Connecting to $deviceName…" }
        frame = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            addView(surfaceView, FrameLayout.LayoutParams(1, 1, Gravity.CENTER))
            addView(status, FrameLayout.LayoutParams(-2, -2, Gravity.CENTER))
        }
        val nav = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setBackgroundColor(Color.parseColor("#CC000000"))
            for ((label, key) in listOf("◁" to ScrcpyControl.KEY_BACK, "○" to ScrcpyControl.KEY_HOME, "□" to ScrcpyControl.KEY_APP_SWITCH)) {
                addView(Button(context).apply {
                    text = label; setTextColor(Color.WHITE); setBackgroundColor(Color.TRANSPARENT)
                    contentDescription = when (key) { ScrcpyControl.KEY_BACK -> "Back"; ScrcpyControl.KEY_HOME -> "Home"; else -> "Recents" }
                    setOnClickListener { session?.sendControl(ScrcpyControl.keyPress(key)) }
                }, LinearLayout.LayoutParams(0, -2, 1f))
            }
            addView(Button(context).apply {
                text = "✕"; setTextColor(Color.WHITE); setBackgroundColor(Color.TRANSPARENT); contentDescription = "Stop mirroring"
                setOnClickListener { finish() }
            }, LinearLayout.LayoutParams(0, -2, 1f))
        }
        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(frame, LinearLayout.LayoutParams(-1, 0, 1f))
            addView(nav, LinearLayout.LayoutParams(-1, -2))
        })
        surfaceView.setOnTouchListener { v, e -> onTouch(v, e) }

        val problem = when {
            deviceId == null || transport == null -> "Gossip isn't running."
            !FeatureSettings.getInstance(this).isEnabled(Feature.SCREEN_MIRRORING) -> "Screen mirroring is turned off in Settings."
            transport.isRelayed(deviceId) -> "$deviceName is connected through the relay. Screen mirroring needs the same network."
            else -> null
        }
        if (problem != null || deviceId == null || transport == null) {
            Toast.makeText(this, problem ?: "Gossip isn't running.", Toast.LENGTH_LONG).show()
            finishedByUs = true
            finish()
            return
        }
        session = ScreenViewerSession(transport, IdentityKeyStore.getInstance(this).deviceId, deviceId, deviceName, scope, this).also { it.start() }
    }

    override fun onDestroy() {
        finishedByUs = true
        session?.stop()
        releaseCodec()
        audioTrack?.release(); audioTrack = null
        scope.cancel()
        super.onDestroy()
    }

    // ---- ScreenViewerSession.Listener (called off the main thread) ------------------------------------------------

    override fun onHeader(header: BridgeStreamHeader) {
        runOnUiThread {
            status.visibility = View.GONE
            fit(header.width, header.height)
        }
        if (header.audioSampleRate != null && header.audioChannels != null) startAudio(header.audioSampleRate, header.audioChannels)
        synchronized(lock) { videoWidth = header.width; videoHeight = header.height }
    }

    override fun onMessage(message: BridgeMessage) {
        when (message) {
            is BridgeMessage.Video -> onVideo(message)
            is BridgeMessage.Size -> {
                synchronized(lock) { videoWidth = message.width; videoHeight = message.height }
                runOnUiThread { fit(message.width, message.height) }
                // The encoder restarted at the new size: rebuild the decoder, then ask for config + a key frame.
                releaseCodec()
                session?.sendControl(ScrcpyControl.RESET_VIDEO)
            }
            is BridgeMessage.Audio -> audioTrack?.write(message.pcm, 0, message.pcm.size, AudioTrack.WRITE_NON_BLOCKING)
            is BridgeMessage.DeviceMessage -> Unit
        }
    }

    override fun onEnded(error: String?) {
        runOnUiThread {
            if (error != null && !isFinishing) Toast.makeText(this, error, Toast.LENGTH_LONG).show()
            if (!finishedByUs) { finishedByUs = true; finish() }
        }
    }

    // ---- Decoding -------------------------------------------------------------------------------------------------

    private fun onVideo(v: BridgeMessage.Video) = synchronized(lock) {
        if (v.isConfig) {
            pendingConfig = v.payload
            releaseCodecLocked()
        }
        val c = codec ?: createCodecLocked() ?: return@synchronized
        runCatching {
            val index = c.dequeueInputBuffer(10_000)
            if (index >= 0) {
                val buf = c.getInputBuffer(index)!!
                buf.clear(); buf.put(v.payload)
                c.queueInputBuffer(index, 0, v.payload.size, v.ptsUs, if (v.isKeyFrame) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
            }
            val info = MediaCodec.BufferInfo()
            while (true) {
                val out = c.dequeueOutputBuffer(info, 0)
                if (out < 0) break
                c.releaseOutputBuffer(out, true)
            }
        }.onFailure {
            Log.w(TAG, "decode failed: ${it.message}")
            releaseCodecLocked()
            session?.sendControl(ScrcpyControl.RESET_VIDEO)
        }
    }

    /** Needs the surface, the video size and the config packet (SPS/PPS); returns null until all three exist. */
    private fun createCodecLocked(): MediaCodec? {
        val s = surface ?: return null
        val config = pendingConfig ?: return null
        if (videoWidth <= 0 || videoHeight <= 0) return null
        return runCatching {
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, videoWidth, videoHeight)
            format.setByteBuffer("csd-0", ByteBuffer.wrap(config))
            format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC).also {
                it.configure(format, s, null, 0)
                it.start()
                codec = it
            }
        }.onFailure { Log.w(TAG, "decoder setup failed: ${it.message}") }.getOrNull()
    }

    private fun releaseCodec() = synchronized(lock) { releaseCodecLocked() }

    private fun releaseCodecLocked() {
        runCatching { codec?.stop() }; runCatching { codec?.release() }
        codec = null
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        synchronized(lock) { surface = holder.surface }
        session?.sendControl(ScrcpyControl.RESET_VIDEO) // a key frame for the new surface
    }
    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) = Unit
    override fun surfaceDestroyed(holder: SurfaceHolder) {
        synchronized(lock) { releaseCodecLocked(); surface = null }
    }

    /** Letterboxes the SurfaceView to the video's aspect ratio inside the frame (MediaCodec stretches to the surface). */
    private fun fit(w: Int, h: Int) {
        if (w <= 0 || h <= 0) return
        frame.post {
            val fw = frame.width.toFloat(); val fh = frame.height.toFloat()
            if (fw <= 0 || fh <= 0) return@post
            val scale = minOf(fw / w, fh / h)
            surfaceView.layoutParams = FrameLayout.LayoutParams((w * scale).toInt().coerceAtLeast(1), (h * scale).toInt().coerceAtLeast(1), Gravity.CENTER)
        }
    }

    // ---- Audio ----------------------------------------------------------------------------------------------------

    private fun startAudio(sampleRate: Int, channels: Int) {
        val mask = if (channels == 1) AudioFormat.CHANNEL_OUT_MONO else AudioFormat.CHANNEL_OUT_STEREO
        runCatching {
            val min = AudioTrack.getMinBufferSize(sampleRate, mask, AudioFormat.ENCODING_PCM_16BIT)
            audioTrack = AudioTrack.Builder()
                .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).build())
                .setAudioFormat(AudioFormat.Builder().setSampleRate(sampleRate).setChannelMask(mask).setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
                .setBufferSizeInBytes(maxOf(min * 4, sampleRate * channels * 2 / 5))
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build().also { it.play() }
        }.onFailure { Log.w(TAG, "audio setup failed: ${it.message}") }
    }

    // ---- Input ----------------------------------------------------------------------------------------------------

    private fun onTouch(v: View, e: MotionEvent): Boolean {
        val w: Int; val h: Int
        synchronized(lock) { w = videoWidth; h = videoHeight }
        if (w <= 0 || h <= 0 || v.width <= 0 || v.height <= 0) return true
        fun send(action: Int, index: Int) {
            val x = (e.getX(index) / v.width * w).toInt().coerceIn(0, w - 1)
            val y = (e.getY(index) / v.height * h).toInt().coerceIn(0, h - 1)
            session?.sendControl(ScrcpyControl.touch(action, e.getPointerId(index).toLong(), x, y, w, h))
        }
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> send(ScrcpyControl.ACTION_DOWN, e.actionIndex)
            MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> send(ScrcpyControl.ACTION_UP, e.actionIndex)
            MotionEvent.ACTION_CANCEL -> for (i in 0 until e.pointerCount) send(ScrcpyControl.ACTION_UP, i)
            MotionEvent.ACTION_MOVE -> for (i in 0 until e.pointerCount) send(ScrcpyControl.ACTION_MOVE, i)
        }
        return true
    }

    companion object {
        private const val EXTRA_DEVICE_ID = "deviceId"
        private const val EXTRA_DEVICE_NAME = "deviceName"

        fun start(context: Context, deviceId: String, deviceName: String) {
            context.startActivity(
                Intent(context, ScreenViewerActivity::class.java)
                    .putExtra(EXTRA_DEVICE_ID, deviceId).putExtra(EXTRA_DEVICE_NAME, deviceName)
            )
        }
    }
}
