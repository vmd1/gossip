package dev.vmd1.gossip.features.clipboard

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import dev.vmd1.gossip.util.Log
import androidx.core.content.FileProvider
import dev.vmd1.gossip.features.hotspot.ShizukuManager
import dev.vmd1.gossip.protocol.Envelope
import dev.vmd1.gossip.protocol.MessageType
import dev.vmd1.gossip.transport.TransportManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import uniffi.gossip_ffi.ClipboardGuard as CoreClipboardGuard
import uniffi.gossip_ffi.clipboardTextSlot
import java.io.ByteArrayOutputStream
import java.io.File

private const val TAG = "ClipboardSyncManager"

/**
 * Bidirectional clipboard sync between this Android device and the rest of the mesh —
 * plain text, which travels as the `clipboard.text` state slot (so the core keeps it correct
 * across reconnects, see `docs/plans/state-sync.md`), and images, which are `clipboard.update`
 * messages whose bytes travel as a raw follow-up frame per `docs/wire-protocol.md`'s "Large
 * binary payloads" convention, relayed hop-by-hop alongside their metadata envelope — see
 * [TransportManager]'s receive loop.
 *
 * **Known platform limitation, and its Shizuku-conditional fix**: since Android 10, a
 * background app — even a foreground [android.app.Service] like
 * [dev.vmd1.gossip.service.SyncForegroundService] — is denied [ClipboardManager.getPrimaryClip]
 * reads unless its app currently has window focus (confirmed directly via
 * `ClipboardService`'s own logcat: "Denying clipboard access... application is not in
 * focus"). *Writing* to the clipboard (the receive direction, in
 * [onRemoteUpdate]/[onRemoteImageUpdate]) is not subject to this restriction and works
 * from the background as normal. An `AccessibilityService`-based workaround was tried and
 * confirmed *not* to grant the exemption on this device (Samsung/One UI).
 *
 * **When [ShizukuManager] is connected** (optional — see `features/hotspot/ShizukuManager
 * .kt`; the same one-time grant Instant Hotspot uses), [runBackgroundPollLoop] periodically
 * reads the clipboard via [ShizukuClipboardReader] instead — a Shizuku-brokered shell-UID
 * call to the raw hidden `IClipboard` interface, which isn't subject to the focus check —
 * confirmed via a real, currently-maintained reference app doing exactly this for the same
 * Mac↔Android clipboard-sync purpose (`github.com/chakri192/clipsyncd`). **Text only**; an
 * image copy made while backgrounded still isn't picked up until the app regains focus —
 * see [ShizukuClipboardReader]'s doc for why. **Without Shizuku** (not installed/granted),
 * the standard technique real clipboard-manager apps use instead is inspecting the
 * accessibility *node tree* for a detected copy action rather than calling the Clipboard
 * API at all — text-only and fragile across arbitrary third-party apps' UI structures, not
 * implemented here; outbound text/image sync then only reliably fires while Connect's own
 * UI is the foregrounded app. This does not affect Mac → Android sync either way.
 *
 * The content policy and the loop suppression (writing the clipboard ourselves in response to a peer
 * fires [ClipboardManager.OnPrimaryClipChangedListener] exactly like a real local copy and must not be
 * echoed back) are the core's `ClipboardGuard` (`desktop/core/src/features/clipboard.rs`), shared with
 * every platform.
 */
class ClipboardSyncManager(
    private val context: Context,
    private val transportManager: TransportManager,
    private val deviceId: String,
    private val scope: CoroutineScope,
    private val shizukuManager: ShizukuManager? = null,
    /** Local clipboard reads aren't messages, so the transport-level feature gate can't cover them. */
    private val isEnabled: () -> Boolean = { true }
) {
    private val clipboardManager =
        context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

    private val guardLogic = CoreClipboardGuard()
    private val history = ClipboardHistoryStore.getInstance(context)

    /** The last local text observed by *either* [onLocalClipChanged] (the focus-gated listener) or [runBackgroundPollLoop]
     *  (the Shizuku-driven poll) — shared so the same genuinely-new text isn't published twice if both paths happen to
     *  observe it. */
    @Volatile
    private var lastObservedText: String? = null

    private val clipListener = ClipboardManager.OnPrimaryClipChangedListener { onLocalClipChanged() }

    @Volatile
    private var started = false

    private var pollJob: Job? = null
    private var stateJob: Job? = null

    /** Starts listening for local clipboard changes and for peers' clipboard text — see this class's doc for why the
     *  local-read side only reliably fires while Connect's own UI has focus, unless [shizukuManager] is connected. Call
     *  once the transport is CONNECTED. Publishes whatever is on the clipboard now (a copy made while disconnected is picked
     *  up here); the core ignores a value it already has, so this is safe to repeat. */
    fun start() {
        if (started) return
        started = true
        clipboardManager.addPrimaryClipChangedListener(clipListener)
        stateJob = scope.launch {
            transportManager.stateChanges.collect { change ->
                if (change.slot == clipboardTextSlot()) change.value?.let { onRemoteText(it.toString()) }
            }
        }
        ClipboardPolicy.pruneCache(File(context.cacheDir, "clipboard")) // leftovers from earlier runs
        transportManager.onRawFrameReceived = { envelope, data -> onRemoteImageUpdate(envelope, data) }
        if (shizukuManager != null) {
            pollJob = scope.launch { runBackgroundPollLoop() }
        }
        publishCurrentClipboard()
    }

    /** Stops listening/handling. Call when the transport disconnects. */
    fun stop() {
        if (!started) return
        started = false
        clipboardManager.removePrimaryClipChangedListener(clipListener)
        stateJob?.cancel()
        stateJob = null
        transportManager.onRawFrameReceived = null
        pollJob?.cancel()
        pollJob = null
    }

    /** Publishes whatever is currently on the clipboard (text takes priority, matching [onLocalClipChanged]), regardless of
     *  whether it was just observed as "new"; the guard drops what was already sent or is an echo. */
    private fun publishCurrentClipboard() {
        if (!isEnabled()) return
        val text = currentClipText()
        if (text != null) {
            lastObservedText = text
            publishText(text)
            return
        }
        val imageBytes = currentClipImagePng() ?: return
        sendImage(imageBytes)
    }

    private fun onLocalClipChanged() {
        val text = currentClipText()
        // The history is its own feature: it records local copies whether or not clipboard sync is on.
        if (text != null) history.record(text, remote = false)
        if (!isEnabled()) return
        if (text != null) {
            handleObservedText(text)
            return
        }
        val imageBytes = currentClipImagePng() ?: return
        sendImage(imageBytes)
    }

    /** Periodically reads the clipboard via [ShizukuClipboardReader] while [shizukuManager] is connected — the
     *  background-capable counterpart to [onLocalClipChanged]'s focus-gated listener. A no-op tick (not ready, unchanged,
     *  or a remote echo) is cheap and expected most of the time; see [ShizukuClipboardReader]'s doc for why this is
     *  text-only. */
    private suspend fun runBackgroundPollLoop() {
        while (true) {
            delay(SHIZUKU_POLL_INTERVAL_MS)
            if (!ShizukuClipboardReader.isReady(shizukuManager)) continue
            val text = ShizukuClipboardReader.readText() ?: continue
            if (text != lastObservedText) history.record(text, remote = false)
            if (!isEnabled()) continue
            handleObservedText(text)
        }
    }

    private fun handleObservedText(text: String) {
        if (text == lastObservedText) return
        lastObservedText = text
        publishText(text)
    }

    /** Sets the `clipboard.text` slot when the guard says this is a genuine local copy (not a peer's value echoed back, not
     *  one already published, not sensitive or too large). */
    private fun publishText(text: String) {
        val value = guardLogic.outgoingText(deviceId, text, false) ?: return
        transportManager.setState(clipboardTextSlot(), Json.parseToJsonElement(value))
    }

    private fun sendImage(data: ByteArray) {
        val outgoing = guardLogic.outgoingImage(deviceId, data, false) ?: return
        scope.launch {
            runCatching {
                val envelope = Envelope(
                    type = outgoing.kind,
                    senderId = deviceId,
                    broadcast = true,
                    hasRawFollowup = true,
                    payload = Json.parseToJsonElement(outgoing.payloadJson) as JsonObject
                )
                transportManager.send(envelope, data)
            }.onFailure { Log.w(TAG, "Failed to send clipboard image: ${it.message}") }
        }
    }

    /** A peer's `clipboard.text` slot changed. */
    private fun onRemoteText(valueJson: String) {
        val text = runCatching { guardLogic.incomingText(valueJson) }.getOrNull() ?: return
        history.record(text, remote = true) // before the write: the write fires our own clip listener, which would record it as local
        clipboardManager.setPrimaryClip(ClipData.newPlainText("Gossip", text))
    }

    /** Puts a history entry back on the clipboard and publishes it (the guard drops it if it is already the current value). */
    fun copyFromHistory(text: String) {
        clipboardManager.setPrimaryClip(ClipData.newPlainText("Gossip", text))
        lastObservedText = text
        history.record(text, remote = false)
        if (isEnabled()) publishText(text)
    }

    private fun onRemoteImageUpdate(envelope: Envelope, data: ByteArray) {
        if (envelope.type != MessageType.CLIPBOARD_UPDATE) return
        if (!ClipboardPolicy.imageBytesAllowed(data.size)) return
        // Refuse anything that isn't a reasonably-sized image before it touches disk or the clipboard.
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
        if (!ClipboardPolicy.imageDimensionsAllowed(bounds.outWidth, bounds.outHeight)) return
        if (runCatching { guardLogic.incomingImage(envelope.payload.toString(), data) }.getOrNull() != true) return

        runCatching {
            val dir = File(context.cacheDir, "clipboard").apply { mkdirs() }
            val file = File(dir, "clip_${System.currentTimeMillis()}.png")
            file.writeBytes(data)
            ClipboardPolicy.pruneCache(dir, keep = file) // only the image now on the clipboard is needed
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.clipboardprovider", file)
            context.grantUriPermission(context.packageName, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            val clip = ClipData.newUri(context.contentResolver, "Gossip", uri)
            clipboardManager.setPrimaryClip(clip)
        }.onFailure { Log.w(TAG, "Failed to write received clipboard image: ${it.message}") }
    }

    private fun currentClipText(): String? {
        val clip = clipboardManager.primaryClip ?: return null
        if (clip.itemCount == 0) return null
        if (clip.description.hasMimeType("image/*")) return null
        if (ClipboardPolicy.isSensitive(clip.description.extras)) return null // password managers etc.
        return clip.getItemAt(0)?.coerceToText(context)?.toString()?.takeIf { ClipboardPolicy.textAllowed(it) }
    }

    /** Reads whatever image is on the clipboard (if any) via its `content://` Uri and
     *  normalizes it to PNG — regardless of the source app's original format — so the
     *  wire format is always a single, universally-decodable content type. Mirrors Mac's
     *  `ClipboardSyncManager.imagePNGData(from:)`. */
    private fun currentClipImagePng(): ByteArray? {
        val clip = clipboardManager.primaryClip ?: return null
        if (clip.itemCount == 0) return null
        if (!clip.description.hasMimeType("image/*")) return null
        if (ClipboardPolicy.isSensitive(clip.description.extras)) return null
        val uri = clip.getItemAt(0)?.uri ?: return null
        return runCatching {
            // Check the dimensions before decoding so a huge image can't exhaust memory.
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
            if (!ClipboardPolicy.imageDimensionsAllowed(bounds.outWidth, bounds.outHeight)) return@runCatching null
            context.contentResolver.openInputStream(uri)?.use { input ->
                val bitmap = BitmapFactory.decodeStream(input) ?: return@use null
                val out = ByteArrayOutputStream()
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
                out.toByteArray().takeIf { ClipboardPolicy.imageBytesAllowed(it.size) }
            }
        }.getOrNull()
    }

    companion object {
        /** How often [runBackgroundPollLoop] re-reads the clipboard via Shizuku. Short enough that a background copy feels
         *  responsive, cheap enough (a single Binder round-trip) that polling this often isn't a real cost. */
        private const val SHIZUKU_POLL_INTERVAL_MS = 2_000L
    }
}
