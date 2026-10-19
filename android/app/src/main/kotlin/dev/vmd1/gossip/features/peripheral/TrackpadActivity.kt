package dev.vmd1.gossip.features.peripheral

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import dev.vmd1.gossip.crypto.IdentityKeyStore
import dev.vmd1.gossip.transport.TransportManagerHolder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.hypot

/**
 * Uses this phone as a Mac's trackpad and keyboard. One finger moves the pointer, a tap clicks, a two-finger tap
 * right-clicks, two fingers scroll; the keyboard button opens the soft keyboard and a row of keys covers Esc, Tab and
 * the arrows. The Mac has to opt in (Gossip → Settings → Phone as trackpad & keyboard) and grant Accessibility.
 */
class TrackpadActivity : Activity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var sender: PeripheralInputSender? = null
    private val handler = Handler(Looper.getMainLooper())
    private val flusher = object : Runnable {
        override fun run() { sender?.flush(); handler.postDelayed(this, FLUSH_MS) }
    }

    // Gesture state
    private var lastX = 0f; private var lastY = 0f
    private var downX = 0f; private var downY = 0f; private var downTime = 0L
    private var moved = false; private var maxPointers = 0
    private var lastTapTime = 0L; private var dragging = false

    private lateinit var input: EditText
    private lateinit var banner: TextView
    private var suppress = false
    private var macId: String? = null
    private var macName = "the Mac"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val macId = intent.getStringExtra(EXTRA_DEVICE_ID)
        val name = intent.getStringExtra(EXTRA_DEVICE_NAME) ?: "Mac"
        this.macId = macId; macName = name
        val transport = TransportManagerHolder.instance
        if (macId == null || transport == null) {
            Toast.makeText(this, "Gossip isn't running.", Toast.LENGTH_LONG).show(); finish(); return
        }
        sender = PeripheralInputSender(transport, IdentityKeyStore.getInstance(this).deviceId, macId, scope)

        val pad = FrameLayout(this).apply {
            setBackgroundColor(Color.parseColor("#222222"))
            banner = TextView(context).apply {
                setTextColor(Color.WHITE); setBackgroundColor(Color.parseColor("#C0392B")); textSize = 14f
                setPadding(32, 24, 32, 24); visibility = View.GONE
            }
            addView(TextView(context).apply {
                text = "$name\nMove: one finger · Click: tap · Right-click: two-finger tap\nScroll: two fingers"
                setTextColor(Color.GRAY); gravity = Gravity.CENTER; textSize = 14f
            }, FrameLayout.LayoutParams(-1, -1))
            addView(banner, FrameLayout.LayoutParams(-1, -2, Gravity.TOP))
            setOnTouchListener { _, e -> onPadTouch(e) }
        }

        input = EditText(this).apply {
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
            setText(SENTINEL); setSelection(1); setTextColor(Color.WHITE); setBackgroundColor(Color.parseColor("#333333"))
            alpha = 0.01f; height = 1
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
                override fun afterTextChanged(s: Editable?) = Unit
                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
                    if (suppress || s == null) return
                    val typed = if (count > 0) s.subSequence(start, start + count).toString() else ""
                    val deleted = (before - count).coerceAtLeast(0)
                    repeat(deleted) { sender?.key("backspace") }
                    if (typed.isNotEmpty() && count >= before) {
                        for (part in typed.split("\n").withIndex()) {
                            if (part.index > 0) sender?.key("return")
                            sender?.text(part.value.replace(SENTINEL, ""))
                        }
                    }
                    if (!s.startsWith(SENTINEL) || s.length > 400) resetInput()
                }
            })
            setOnEditorActionListener { _, _, _ -> sender?.key("return"); true }
        }

        fun keyButton(label: String, key: String) = Button(this).apply {
            text = label; setTextColor(Color.WHITE); setBackgroundColor(Color.TRANSPARENT); isAllCaps = false
            contentDescription = key
            setOnClickListener { sender?.key(key) }
        }
        val keys = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; setBackgroundColor(Color.parseColor("#111111"))
            addView(Button(context).apply {
                text = "⌨"; setTextColor(Color.WHITE); setBackgroundColor(Color.TRANSPARENT); contentDescription = "Keyboard"
                setOnClickListener { input.requestFocus(); (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager).showSoftInput(input, 0) }
            }, LinearLayout.LayoutParams(0, -2, 1f))
            for ((l, k) in listOf("esc" to "escape", "tab" to "tab", "←" to "left", "↑" to "up", "↓" to "down", "→" to "right", "⌫" to "backspace", "⏎" to "return")) {
                addView(keyButton(l, k), LinearLayout.LayoutParams(0, -2, 1f))
            }
        }
        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(pad, LinearLayout.LayoutParams(-1, 0, 1f))
            addView(input, LinearLayout.LayoutParams(-1, 1))
            addView(keys, LinearLayout.LayoutParams(-1, -2))
        })
        handler.post(flusher)
        watchStatus(transport, macId)
    }

    /** Shows why the trackpad won't work (feature off on the Mac, missing permission, Mac not connected) and keeps it current. */
    private fun watchStatus(transport: dev.vmd1.gossip.transport.TransportManager, macId: String) {
        fun refresh() {
            val connected = macId in transport.connectedDeviceIds.value || macId in transport.relayedDeviceIds.value ||
                macId in transport.meshReachableDeviceIds.value
            val problem = TrackpadStatus.problem(macName, connected, transport.state(macId, TrackpadStatus.SLOT))
            runOnUiThread {
                banner.text = problem ?: ""
                val wasHidden = banner.visibility != View.VISIBLE
                banner.visibility = if (problem == null) View.GONE else View.VISIBLE
                if (problem != null && wasHidden) Toast.makeText(this, problem, Toast.LENGTH_LONG).show()
            }
        }
        refresh()
        scope.launch {
            kotlinx.coroutines.flow.merge(
                transport.stateChanges.map { }, transport.connectedDeviceIds.map { }, transport.relayedDeviceIds.map { }
            ).collect { refresh() }
        }
    }

    private fun resetInput() {
        suppress = true
        input.setText(SENTINEL); input.setSelection(1)
        suppress = false
    }

    override fun onDestroy() {
        handler.removeCallbacks(flusher)
        sender?.flush(); sender?.close()
        scope.cancel()
        super.onDestroy()
    }

    private fun onPadTouch(e: MotionEvent): Boolean {
        val s = sender ?: return true
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                lastX = e.x; lastY = e.y; downX = e.x; downY = e.y; downTime = e.eventTime
                moved = false; maxPointers = 1
                // A second tap shortly after a first one and then dragging is "tap-drag": hold the button.
                dragging = e.eventTime - lastTapTime < DOUBLE_TAP_MS
                if (dragging) s.button(0, true)
            }
            MotionEvent.ACTION_POINTER_DOWN -> {
                maxPointers = maxOf(maxPointers, e.pointerCount)
                lastX = avgX(e); lastY = avgY(e)
            }
            MotionEvent.ACTION_MOVE -> {
                val x = avgX(e); val y = avgY(e)
                if (hypot(x - downX, y - downY) > TAP_SLOP) moved = true
                val dx = x - lastX; val dy = y - lastY
                lastX = x; lastY = y
                if (e.pointerCount >= 2) s.addScroll(dx * SCROLL_GAIN, dy * SCROLL_GAIN)
                else s.addMove(accelerate(dx), accelerate(dy))
            }
            MotionEvent.ACTION_POINTER_UP -> {
                // Lifting one of two fingers: re-anchor on the remaining one so there is no jump.
                val keep = if (e.actionIndex == 0) 1 else 0
                if (keep < e.pointerCount) { lastX = e.getX(keep); lastY = e.getY(keep) }
            }
            MotionEvent.ACTION_UP -> {
                val quick = e.eventTime - downTime < TAP_MS
                if (dragging) {
                    s.button(0, false)
                    lastTapTime = 0
                } else if (!moved && quick) {
                    if (maxPointers >= 2) s.click(1) else { s.click(0); lastTapTime = e.eventTime }
                }
            }
            MotionEvent.ACTION_CANCEL -> if (dragging) s.button(0, false)
        }
        return true
    }

    private fun avgX(e: MotionEvent) = (0 until e.pointerCount).map { e.getX(it) }.average().toFloat()
    private fun avgY(e: MotionEvent) = (0 until e.pointerCount).map { e.getY(it) }.average().toFloat()

    /** A gentle pointer acceleration curve: slow movements stay precise, fast ones cover the screen. */
    private fun accelerate(d: Float): Float {
        val a = abs(d)
        return d * (1.2f + minOf(a / 12f, 2.5f))
    }

    companion object {
        private const val EXTRA_DEVICE_ID = "deviceId"
        private const val EXTRA_DEVICE_NAME = "deviceName"
        private const val SENTINEL = "​"
        private const val FLUSH_MS = 12L
        private const val TAP_MS = 250L
        private const val DOUBLE_TAP_MS = 300L
        private const val TAP_SLOP = 18f
        private const val SCROLL_GAIN = 0.8f

        fun start(context: Context, deviceId: String, deviceName: String) {
            context.startActivity(
                Intent(context, TrackpadActivity::class.java)
                    .putExtra(EXTRA_DEVICE_ID, deviceId).putExtra(EXTRA_DEVICE_NAME, deviceName)
            )
        }
    }
}
