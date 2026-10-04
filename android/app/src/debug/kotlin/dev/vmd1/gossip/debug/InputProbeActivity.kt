package dev.vmd1.gossip.debug

import android.app.Activity
import android.graphics.Color
import android.os.Bundle
import android.util.Log
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.widget.TextView

/**
 * Debug-only probe. Fills the screen and logs every pointer, scroll and key event it receives to logcat
 * under tag `GossipProbe`, one line each, so scripts can assert on exactly what the system delivered:
 *
 *  - `ptr action=HOVER_MOVE x=.. y=.. buttons=0x.. src=0x.. tool=MOUSE`
 *  - `scroll v=.. h=.. x=.. y=..`
 *  - `key action=DOWN code=KEYCODE_A meta=0x.. char=a`
 *  - `display w=.. h=.. rotation=..` on every layout (so rotation can be asserted)
 *
 * It never changes behavior; start it with `adb shell am start -n dev.vmd1.gossip/.debug.InputProbeActivity`.
 */
class InputProbeActivity : Activity() {
    private lateinit var status: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setShowWhenLocked(true) // so the probe is usable (and scriptable) without unlocking the device
        setTurnScreenOn(true)
        status = TextView(this).apply {
            setBackgroundColor(Color.rgb(20, 20, 30)); setTextColor(Color.WHITE); textSize = 16f
            text = "Gossip input probe"
            isFocusable = true; isFocusableInTouchMode = true
            addOnLayoutChangeListener { v, _, _, _, _, _, _, _, _ ->
                Log.i(TAG, "display w=${v.width} h=${v.height} rotation=${display?.rotation}")
            }
        }
        setContentView(status)
        status.requestFocus()
    }

    private fun describe(e: MotionEvent) =
        "action=${MotionEvent.actionToString(e.actionMasked)} x=${"%.1f".format(e.x)} y=${"%.1f".format(e.y)} " +
            "buttons=0x${e.buttonState.toString(16)} src=0x${e.source.toString(16)} tool=${e.getToolType(0)} " +
            "dev=${e.device?.name}"

    override fun dispatchGenericMotionEvent(e: MotionEvent): Boolean {
        if (e.actionMasked == MotionEvent.ACTION_SCROLL) {
            Log.i(TAG, "scroll v=${e.getAxisValue(MotionEvent.AXIS_VSCROLL)} h=${e.getAxisValue(MotionEvent.AXIS_HSCROLL)} x=${e.x} y=${e.y}")
        } else {
            Log.i(TAG, "ptr ${describe(e)}")
        }
        status.text = "ptr ${e.x.toInt()},${e.y.toInt()}"
        return true
    }

    override fun dispatchTouchEvent(e: MotionEvent): Boolean {
        Log.i(TAG, "ptr ${describe(e)}")
        return true
    }

    override fun dispatchKeyEvent(e: KeyEvent): Boolean {
        Log.i(
            TAG,
            "key action=${if (e.action == KeyEvent.ACTION_DOWN) "DOWN" else "UP"} code=${KeyEvent.keyCodeToString(e.keyCode)} " +
                "meta=0x${e.metaState.toString(16)} char=${e.unicodeChar.takeIf { it > 0 }?.toChar() ?: ""} repeat=${e.repeatCount} dev=${e.device?.name}",
        )
        return true
    }

    private companion object { const val TAG = "GossipProbe" }
}
