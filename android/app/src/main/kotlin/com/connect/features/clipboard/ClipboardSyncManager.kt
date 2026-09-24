package com.connect.features.clipboard

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Log
import androidx.core.content.FileProvider
import com.connect.protocol.Envelope
import com.connect.protocol.MessageType
import com.connect.transport.EnvelopeHandler
import com.connect.transport.MessageRouter
import com.connect.transport.TransportManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.ByteArrayOutputStream
import java.io.File

private const val TAG = "ClipboardSyncManager"

/**
 * Bidirectional clipboard sync between this Android device and the rest of the mesh —
 * plain text (broadcast, relayed through the whole mesh like any other message) and
 * images (broadcast too, but the actual bytes travel as a raw follow-up frame per
 * `docs/wire-protocol.md`'s "Large binary payloads" convention, relayed hop-by-hop
 * alongside their metadata envelope — see [TransportManager]'s receive loop).
 *
 * **Known platform limitation**: since Android 10, a background app — even a foreground
 * [android.app.Service] like [com.connect.service.SyncForegroundService] — is denied
 * [ClipboardManager.getPrimaryClip] reads unless its app currently has window focus
 * (confirmed directly via `ClipboardService`'s own logcat: "Denying clipboard access...
 * application is not in focus"). *Writing* to the clipboard (the receive direction, in
 * [onRemoteUpdate]/[onRemoteImageUpdate]) is not subject to this restriction and works
 * from the background as normal. An `AccessibilityService`-based workaround was tried and
 * confirmed *not* to grant the exemption on this device (Samsung/One UI) — the standard
 * technique real clipboard-manager apps use instead is inspecting the accessibility
 * *node tree* for a detected copy action rather than calling the Clipboard API at all,
 * which is text-only and fragile across arbitrary third-party apps' UI structures; not
 * implemented here. Practical effect: outbound sync (Android → mesh) only reliably fires
 * while Connect's own UI is the foregrounded app on Android — e.g. right after switching
 * to it, or while its window has focus. This does not affect Mac → Android sync.
 *
 * Loop suppression: writing to the clipboard ourselves (in response to a remote update)
 * fires [ClipboardManager.OnPrimaryClipChangedListener] exactly like a real local copy
 * would, which would otherwise get echoed straight back to the sender. To avoid that we
 * remember the last value *we* wrote programmatically (text or image, whichever) and
 * skip sending when the newly-observed clipboard content matches it exactly.
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

    @Volatile
    private var lastRemoteSetImageData: ByteArray? = null

    private val clipListener = ClipboardManager.OnPrimaryClipChangedListener { onLocalClipChanged() }

    private val envelopeHandler = EnvelopeHandler { envelope -> onRemoteUpdate(envelope) }

    @Volatile
    private var started = false

    /** Starts listening for local clipboard changes and registers the wire handlers —
     *  see this class's doc for why the local-read side only reliably fires while
     *  Connect's own UI has focus. Call once the transport is CONNECTED. */
    fun start() {
        if (started) return
        started = true
        clipboardManager.addPrimaryClipChangedListener(clipListener)
        messageRouter.register(MessageType.CLIPBOARD_UPDATE, envelopeHandler)
        transportManager.onRawFrameReceived = { envelope, data -> onRemoteImageUpdate(envelope, data) }
    }

    /** Stops listening/handling. Call when the transport disconnects. */
    fun stop() {
        if (!started) return
        started = false
        clipboardManager.removePrimaryClipChangedListener(clipListener)
        messageRouter.unregister(envelopeHandler)
        transportManager.onRawFrameReceived = null
    }

    private fun onLocalClipChanged() {
        val text = currentClipText()
        if (text != null) {
            if (!shouldSend(text, lastRemoteSetValue)) return
            sendText(text)
            return
        }

        val imageBytes = currentClipImagePng() ?: return
        if (!shouldSendImage(imageBytes, lastRemoteSetImageData)) return
        sendImage(imageBytes)
    }

    private fun sendText(text: String) {
        scope.launch {
            runCatching {
                transportManager.send(
                    Envelope(
                        type = MessageType.CLIPBOARD_UPDATE,
                        senderId = deviceId,
                        broadcast = true,
                        payload = JsonObject(
                            mapOf(
                                "kind" to JsonPrimitive("text"),
                                "text" to JsonPrimitive(text),
                                "sourceDeviceId" to JsonPrimitive(deviceId)
                            )
                        )
                    )
                )
            }.onFailure { Log.w(TAG, "Failed to send clipboard.update: ${it.message}") }
        }
    }

    private fun sendImage(data: ByteArray) {
        scope.launch {
            runCatching {
                val envelope = Envelope(
                    type = MessageType.CLIPBOARD_UPDATE,
                    senderId = deviceId,
                    broadcast = true,
                    hasRawFollowup = true,
                    payload = buildJsonObject {
                        put("kind", "image")
                        put("sourceDeviceId", deviceId)
                        put("contentType", "image/png")
                        put("byteLength", data.size)
                    }
                )
                transportManager.send(envelope, data)
            }.onFailure { Log.w(TAG, "Failed to send clipboard image: ${it.message}") }
        }
    }

    private fun onRemoteUpdate(envelope: Envelope) {
        val text = envelope.payload["text"]?.jsonPrimitive?.contentOrNull ?: return
        lastRemoteSetValue = text
        clipboardManager.setPrimaryClip(ClipData.newPlainText("Connect", text))
    }

    private fun onRemoteImageUpdate(envelope: Envelope, data: ByteArray) {
        if (envelope.type != MessageType.CLIPBOARD_UPDATE) return
        if (envelope.payload["kind"]?.jsonPrimitive?.contentOrNull != "image") return
        lastRemoteSetImageData = data

        runCatching {
            val dir = File(context.cacheDir, "clipboard").apply { mkdirs() }
            val file = File(dir, "clip_${System.currentTimeMillis()}.png")
            file.writeBytes(data)
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.clipboardprovider", file)
            context.grantUriPermission(context.packageName, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            val clip = ClipData.newUri(context.contentResolver, "Connect", uri)
            clipboardManager.setPrimaryClip(clip)
        }.onFailure { Log.w(TAG, "Failed to write received clipboard image: ${it.message}") }
    }

    private fun currentClipText(): String? {
        val clip = clipboardManager.primaryClip ?: return null
        if (clip.itemCount == 0) return null
        if (clip.description.hasMimeType("image/*")) return null
        return clip.getItemAt(0)?.coerceToText(context)?.toString()
    }

    /** Reads whatever image is on the clipboard (if any) via its `content://` Uri and
     *  normalizes it to PNG — regardless of the source app's original format — so the
     *  wire format is always a single, universally-decodable content type. Mirrors Mac's
     *  `ClipboardSyncManager.imagePNGData(from:)`. */
    private fun currentClipImagePng(): ByteArray? {
        val clip = clipboardManager.primaryClip ?: return null
        if (clip.itemCount == 0) return null
        if (!clip.description.hasMimeType("image/*")) return null
        val uri = clip.getItemAt(0)?.uri ?: return null
        return runCatching {
            context.contentResolver.openInputStream(uri)?.use { input ->
                val bitmap = BitmapFactory.decodeStream(input) ?: return@use null
                val out = ByteArrayOutputStream()
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
                out.toByteArray()
            }
        }.getOrNull()
    }

    companion object {
        /**
         * Pure loop-suppression check, exposed for unit testing: returns `false` when
         * [newValue] matches [lastRemoteSetValue] (an echo of an update we just applied
         * ourselves, not a genuine local copy), `true` otherwise.
         */
        fun shouldSend(newValue: String, lastRemoteSetValue: String?): Boolean =
            newValue != lastRemoteSetValue

        /** Same loop-suppression check as [shouldSend], for image content. */
        fun shouldSendImage(newImageData: ByteArray, lastRemoteSetImageData: ByteArray?): Boolean =
            lastRemoteSetImageData == null || !newImageData.contentEquals(lastRemoteSetImageData)
    }
}
