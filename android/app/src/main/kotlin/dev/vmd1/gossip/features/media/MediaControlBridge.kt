package dev.vmd1.gossip.features.media

import android.content.ComponentName
import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.util.Base64
import android.util.Log
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

private const val TAG = "MediaControlBridge"

/** `type` values this unit registers in `schema/message-types.md`. */
object MediaMessageType {
    const val NOWPLAYING = "media.nowplaying"
    const val COMMAND = "media.command"
}

/**
 * A parsed, validated `media.command` payload (mac -> android). Kept as a plain data
 * class, independent of the Android media framework, so parsing can be unit tested
 * without instrumentation.
 */
data class MediaCommand(val action: String, val seekMs: Int?) {
    companion object {
        const val ACTION_PLAY = "play"
        const val ACTION_PAUSE = "pause"
        const val ACTION_NEXT = "next"
        const val ACTION_PREVIOUS = "previous"

        private val VALID_ACTIONS = setOf(ACTION_PLAY, ACTION_PAUSE, ACTION_NEXT, ACTION_PREVIOUS)

        /** Returns null for a payload missing `action` or carrying an unrecognized one. */
        fun fromPayload(payload: JsonObject): MediaCommand? {
            val action = (payload["action"] as? JsonPrimitive)?.contentOrNull ?: return null
            if (action !in VALID_ACTIONS) return null
            val seekMs = (payload["seekMs"] as? JsonPrimitive)?.intOrNull
            return MediaCommand(action, seekMs)
        }
    }
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
        val command = MediaCommand.fromPayload(envelope.payload) ?: return
        val controls = activeController?.transportControls ?: return
        when (command.action) {
            MediaCommand.ACTION_PLAY -> controls.play()
            MediaCommand.ACTION_PAUSE -> controls.pause()
            MediaCommand.ACTION_NEXT -> controls.skipToNext()
            MediaCommand.ACTION_PREVIOUS -> controls.skipToPrevious()
        }
        command.seekMs?.let { controls.seekTo(it.toLong()) }
    }

    /** Re-sends the current now-playing snapshot (if any session is active), for a
     *  caller reconciling this device's state to a peer that may have missed the
     *  original event-driven publish — a fresh reconnect, or a periodic self-healing
     *  backstop. See `SyncForegroundService`'s connection-state observer and resync
     *  loop, which call this the same way `DndSyncManager.reportInitialSyncState`/
     *  `RosterGossipManager.periodicResync` are already called for the same reason
     *  (this project's `CLAUDE.md` convention: anything configuring state on a
     *  recipient needs a self-healing resync, not just a one-shot send-on-change). A
     *  no-op — not an error — when nothing is currently playing. */
    fun resyncNowPlaying() = publishNowPlaying()

    private fun publishNowPlaying() {
        val controller = activeController ?: return
        val snapshot = snapshotFrom(controller) ?: return
        // Broadcast (mesh support): every trusted Mac should see this device's
        // now-playing state, not just whichever single peer used to be tracked — each
        // Mac keys its own now-playing state per sender (senderId), so multiple phones'
        // sessions can be shown/controlled independently.
        val envelope = Envelope(
            type = MediaMessageType.NOWPLAYING,
            senderId = identityKeyStore.deviceId,
            broadcast = true,
            payload = snapshot.toPayload()
        )
        scope.launch {
            runCatching { transportManager.send(envelope) }
                .onFailure { Log.w(TAG, "Failed to send media.nowplaying: ${it.message}") }
        }
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
