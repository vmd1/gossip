package com.connect.features.clipboard

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.util.Log
import com.connect.protocol.Envelope
import com.connect.protocol.MessageType
import com.connect.transport.EnvelopeHandler
import com.connect.transport.MessageRouter
import com.connect.transport.TransportManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive

private const val TAG = "ClipboardSyncManager"

/**
 * Bidirectional plain-text clipboard sync between this Android device and its paired peer.
 *
 * Unlike macOS's `NSPasteboard`, Android's [ClipboardManager] offers a push-based
 * [ClipboardManager.OnPrimaryClipChangedListener], so no polling is needed here: every
 * local clipboard change fires the listener immediately, and if it looks like a genuine
 * new value we send a `clipboard.update` envelope. Every received `clipboard.update` is
 * written straight into the system clipboard via [ClipboardManager.setPrimaryClip].
 *
 * Loop suppression: writing to the clipboard ourselves (in response to a remote update)
 * fires [ClipboardManager.OnPrimaryClipChangedListener] exactly like a real local copy
 * would, which would otherwise get echoed straight back to the sender. To avoid that we
 * remember the last value *we* wrote programmatically and skip sending when the
 * newly-observed clipboard text matches it exactly (see [shouldSend]).
 */
class ClipboardSyncManager(
    private val context: Context,
    private val transportManager: TransportManager,
    private val messageRouter: MessageRouter,
    private val deviceId: String,
    private val scope: CoroutineScope
) {
    private val clipboardManager =
        context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

    @Volatile
    private var lastRemoteSetValue: String? = null

    private val clipListener = ClipboardManager.OnPrimaryClipChangedListener { onLocalClipChanged() }

    private val envelopeHandler = EnvelopeHandler { envelope -> onRemoteUpdate(envelope) }

    @Volatile
    private var started = false

    /** Starts listening for local clipboard changes and registers the wire handler. Call
     *  once the transport is CONNECTED. */
    fun start() {
        if (started) return
        started = true
        clipboardManager.addPrimaryClipChangedListener(clipListener)
        messageRouter.register(MessageType.CLIPBOARD_UPDATE, envelopeHandler)
    }

    /** Stops listening/handling. Call when the transport disconnects. */
    fun stop() {
        if (!started) return
        started = false
        clipboardManager.removePrimaryClipChangedListener(clipListener)
        messageRouter.unregister(envelopeHandler)
    }

    private fun onLocalClipChanged() {
        val text = currentClipText() ?: return
        if (!shouldSend(text, lastRemoteSetValue)) return

        scope.launch {
            runCatching {
                transportManager.send(
                    Envelope(
                        type = MessageType.CLIPBOARD_UPDATE,
                        senderId = deviceId,
                        broadcast = true,
                        payload = JsonObject(
                            mapOf(
                                "text" to JsonPrimitive(text),
                                "sourceDeviceId" to JsonPrimitive(deviceId)
                            )
                        )
                    )
                )
            }.onFailure { Log.w(TAG, "Failed to send clipboard.update: ${it.message}") }
        }
    }

    private fun onRemoteUpdate(envelope: Envelope) {
        val text = envelope.payload["text"]?.jsonPrimitive?.contentOrNull ?: return
        lastRemoteSetValue = text
        clipboardManager.setPrimaryClip(ClipData.newPlainText("Connect", text))
    }

    private fun currentClipText(): String? {
        val clip = clipboardManager.primaryClip ?: return null
        if (clip.itemCount == 0) return null
        return clip.getItemAt(0)?.coerceToText(context)?.toString()
    }

    companion object {
        /**
         * Pure loop-suppression check, exposed for unit testing: returns `false` when
         * [newValue] matches [lastRemoteSetValue] (an echo of an update we just applied
         * ourselves, not a genuine local copy), `true` otherwise.
         */
        fun shouldSend(newValue: String, lastRemoteSetValue: String?): Boolean =
            newValue != lastRemoteSetValue
    }
}
