package dev.vmd1.gossip.debug

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import dev.vmd1.gossip.features.universalcontrol.ControlSessionState
import dev.vmd1.gossip.protocol.Envelope
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject

/** Debug-only adb entry point for the scripted Universal Control end-to-end test (see the manifest). */
class ControlDebugReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val state = ControlSessionState.current ?: run { Log.w("ControlDebug", "gossip service not running"); return }
        val sessionId = intent.getStringExtra("sessionId") ?: return
        val type = if (intent.action?.endsWith("CONTROL_END") == true) "control.end" else "control.session_start"
        state.handleDebug(Envelope(type = type, senderId = "debug-adb", recipientId = "self", ttl = 0, payload = buildJsonObject {
            put("sessionId", JsonPrimitive(sessionId)); intent.getStringExtra("secret")?.let { put("secret", JsonPrimitive(it)) }
        }))
    }
}
