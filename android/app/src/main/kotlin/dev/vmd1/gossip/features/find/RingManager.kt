package dev.vmd1.gossip.features.find

import dev.vmd1.gossip.protocol.Envelope
import dev.vmd1.gossip.protocol.MessageType
import dev.vmd1.gossip.transport.EnvelopeHandler
import dev.vmd1.gossip.transport.MessageRouter
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive

/** Plays (and stops) the actual alarm sound — behind an interface so [RingManager]'s dedupe /
 *  auto-stop logic is unit-testable without audio hardware. */
interface Ringer {
    fun start()
    fun stop()
}

/**
 * Handles `device.ring` (see `schema/message-types.md`): a paired device asks this one to ring at
 * full volume so it can be found, or to stop. One-shot trigger, not persistent state, so no resync
 * loop — but it must be idempotent: `start` while already ringing is a no-op, `stop` while silent
 * is a no-op, and a duplicate/late `start` (identified by its per-attempt `ringId`, kept in a
 * bounded recently-handled cache, same pattern as `media.command`'s `commandId`) can never
 * restart a ring the user already stopped. Rings stop on their own after [autoStopMs].
 */
class RingManager(
    private val messageRouter: MessageRouter,
    private val ringer: Ringer,
    private val scope: CoroutineScope,
    private val autoStopMs: Long = AUTO_STOP_MS,
    /** Called whenever ringing starts/stops, so the UI layer can show/remove a "Stop" notification. */
    private val onRingingChanged: (ringing: Boolean) -> Unit = {}
) {
    private val handler = EnvelopeHandler { onEnvelope(it) }
    private val recentRingIds = object : LinkedHashMap<String, Unit>(16, 0.75f, false) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Unit>?) = size > RECENT_CACHE_SIZE
    }
    private var autoStopJob: Job? = null

    @Volatile var isRinging = false
        private set

    fun start() = messageRouter.register(MessageType.DEVICE_RING, handler)
    fun shutdown() { messageRouter.unregister(handler); stopRinging() }

    private fun onEnvelope(envelope: Envelope) {
        val action = envelope.payload["action"]?.jsonPrimitive?.contentOrNull ?: return
        val ringId = envelope.payload["ringId"]?.jsonPrimitive?.contentOrNull ?: return
        when (action) {
            "start" -> synchronized(this) {
                if (recentRingIds.put(ringId, Unit) != null) return  // duplicate / late redelivery
                if (isRinging) return
                isRinging = true
                ringer.start()
                onRingingChanged(true)
                autoStopJob = scope.launch { delay(autoStopMs); stopRinging() }
            }
            "stop" -> stopRinging()
        }
    }

    /** Silences the ring (also wired to the notification's Stop action). No-op when not ringing. */
    @Synchronized
    fun stopRinging() {
        autoStopJob?.cancel(); autoStopJob = null
        if (!isRinging) return
        isRinging = false
        ringer.stop()
        onRingingChanged(false)
    }

    companion object {
        const val AUTO_STOP_MS = 30_000L
        private const val RECENT_CACHE_SIZE = 64

        fun payload(action: String, ringId: String = java.util.UUID.randomUUID().toString()) = buildJsonObject {
            put("action", JsonPrimitive(action))
            put("ringId", JsonPrimitive(ringId))
        }
    }
}
