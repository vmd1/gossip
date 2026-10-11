package dev.vmd1.gossip.features.media

import android.content.ComponentName
import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.util.Base64
import dev.vmd1.gossip.util.Log
import dev.vmd1.gossip.crypto.IdentityKeyStore
import dev.vmd1.gossip.protocol.Envelope
import dev.vmd1.gossip.transport.EnvelopeHandler
import dev.vmd1.gossip.transport.MessageRouter
import dev.vmd1.gossip.transport.TransportManager
import java.io.ByteArrayOutputStream
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put
import uniffi.gossip_ffi.CommandGuard as CoreCommandGuard
import uniffi.gossip_ffi.MediaAction

private const val TAG = "MediaControlBridge"

/** `type` values this unit registers in `schema/message-types.md`. */
object MediaMessageType {
    /** The synchronised state slot a phone keeps its now-playing state in. */
    const val NOWPLAYING_SLOT = "media.nowplaying"
    const val COMMAND = "media.command"
}

/**
 * Plain-data snapshot of a media session's now-playing state (android -> mac),
 * independent of `MediaController`/`MediaMetadata` so it can be unit tested and
 * JSON-encoded directly per the `media.nowplaying` payload shape in
 * `schema/message-types.md`.
 */
data class NowPlayingSnapshot(
    val title: String,
    val artist: String,
    val artBase64: String?,
    val isPlaying: Boolean,
    val positionMs: Long,
    val durationMs: Long,
    val packageName: String
) {
    fun toPayload(): JsonObject = buildJsonObject {
        put("title", title)
        put("artist", artist)
        artBase64?.let { put("artBase64", it) }
        put("isPlaying", isPlaying)
        put("positionMs", positionMs)
        put("durationMs", durationMs)
        put("packageName", packageName)
    }
}

/**
 * Bridges the phone's active [MediaController] session(s) to the wire protocol:
 * mirrors now-playing state to the Mac as `media.nowplaying`, and translates incoming
 * `media.command` envelopes into [MediaController.getTransportControls] calls.
 *
 * Enumerating sessions via [MediaSessionManager.getActiveSessions] requires
 * notification-listener access bound to [MediaNotificationListenerService]'s
 * `ComponentName` — see that class's doc for why a listener service exists at all here.
 * If the user hasn't granted that access yet, [start] logs and no-ops rather than
 * crashing; call [start] again (e.g. on resume) once access may have been granted.
 */
class MediaControlBridge(
    private val context: Context,
    private val messageRouter: MessageRouter,
    private val transportManager: TransportManager,
    private val identityKeyStore: IdentityKeyStore
) {
    private val mediaSessionManager =
        context.getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager
    private val listenerComponent = ComponentName(context, MediaNotificationListenerService::class.java)
    private val scope = CoroutineScope(Dispatchers.Main)

    private var activeController: MediaController? = null

    private val controllerCallback = object : MediaController.Callback() {
        override fun onPlaybackStateChanged(state: PlaybackState?) = publishNowPlaying()
        override fun onMetadataChanged(metadata: MediaMetadata?) = publishNowPlaying()
        override fun onSessionDestroyed() = refreshActiveSessions()
    }

    private val sessionsChangedListener =
        MediaSessionManager.OnActiveSessionsChangedListener { controllers -> refreshActiveSessions(controllers) }

    private val commandHandler = EnvelopeHandler { envelope -> handleCommand(envelope) }

    /** Acts on each `media.command` `commandId` once. `skipToNext()`/`skipToPrevious()` are not idempotent, so a duplicate delivery
     *  (retry, relay race, dedupe-cache eviction) must not skip twice; the bounded recently-handled cache and the validation
     *  are the core's `CommandGuard` (`desktop/core/src/features/media.rs`), shared with every platform. */
    private val commandGuard = CoreCommandGuard()

    /** Registers the `media.command` handler and starts observing active sessions. */
    fun start() {
        messageRouter.register(MediaMessageType.COMMAND, commandHandler)
        try {
            mediaSessionManager.addOnActiveSessionsChangedListener(sessionsChangedListener, listenerComponent)
        } catch (e: SecurityException) {
            Log.w(TAG, "Notification listener access not granted; media controls unavailable for now", e)
            return
        }
        refreshActiveSessions()
    }

    fun stop() {
        messageRouter.unregister(commandHandler)
        runCatching { mediaSessionManager.removeOnActiveSessionsChangedListener(sessionsChangedListener) }
        activeController?.unregisterCallback(controllerCallback)
        activeController = null
    }

    private fun refreshActiveSessions(controllers: List<MediaController>? = null) {
        val sessions = controllers ?: try {
            mediaSessionManager.getActiveSessions(listenerComponent)
        } catch (e: SecurityException) {
            Log.w(TAG, "getActiveSessions failed: notification listener access not granted", e)
            emptyList()
        }

        val chosen = selectMostRelevant(sessions) { it.playbackState?.state == PlaybackState.STATE_PLAYING }
        if (chosen?.sessionToken != activeController?.sessionToken) {
            activeController?.unregisterCallback(controllerCallback)
            activeController = chosen
            chosen?.registerCallback(controllerCallback)
        }
        publishNowPlaying()
    }

    private fun handleCommand(envelope: Envelope) {
        if (envelope.type != MediaMessageType.COMMAND) return
        // `null`: a duplicate delivery or a malformed command.
        val accepted = runCatching { commandGuard.accept(envelope.payload.toString()) }.getOrNull() ?: return
        val controls = activeController?.transportControls ?: return
        when (accepted.action) {
            MediaAction.PLAY -> controls.play()
            MediaAction.PAUSE -> controls.pause()
            MediaAction.NEXT -> controls.skipToNext()
            MediaAction.PREVIOUS -> controls.skipToPrevious()
        }
        accepted.seekMs?.let { controls.seekTo(it) }
    }

    /** Reports the current now-playing state as the `media.nowplaying` state slot. The core sends it to every device that
     *  connects later and repairs it periodically (see `docs/plans/state-sync.md`), so nothing here resends it. No session
     *  (it ended, or never existed) clears the slot, so the Macs stop showing the last track. Setting what the slot
     *  already holds does nothing, so this is safe to call on any event. */
    private fun publishNowPlaying() {
        val snapshot = activeController?.let { snapshotFrom(it) }
        transportManager.setState(MediaMessageType.NOWPLAYING_SLOT, snapshot?.toPayload())
    }

    private fun snapshotFrom(controller: MediaController): NowPlayingSnapshot? {
        val metadata = controller.metadata ?: return null
        val state = controller.playbackState
        val artBitmap = metadata.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART)
            ?: metadata.getBitmap(MediaMetadata.METADATA_KEY_ART)
        return NowPlayingSnapshot(
            title = metadata.getString(MediaMetadata.METADATA_KEY_TITLE).orEmpty(),
            artist = metadata.getString(MediaMetadata.METADATA_KEY_ARTIST).orEmpty(),
            artBase64 = artBitmap?.let { encodeBitmapToBase64(it) },
            isPlaying = state?.state == PlaybackState.STATE_PLAYING,
            positionMs = state?.position ?: 0L,
            durationMs = metadata.getLong(MediaMetadata.METADATA_KEY_DURATION),
            packageName = controller.packageName.orEmpty()
        )
    }

    private fun encodeBitmapToBase64(bitmap: Bitmap): String {
        val stream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, 80, stream)
        return Base64.encodeToString(stream.toByteArray(), Base64.NO_WRAP)
    }

    companion object {
        /**
         * Picks the "most relevant" candidate: the first one matching [isPlaying], falling
         * back to the first available. Generic and framework-independent so it's unit
         * testable without a real [MediaController].
         */
        fun <T> selectMostRelevant(candidates: List<T>, isPlaying: (T) -> Boolean): T? =
            candidates.firstOrNull(isPlaying) ?: candidates.firstOrNull()
    }
}
