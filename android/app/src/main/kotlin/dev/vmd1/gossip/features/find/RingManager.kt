package dev.vmd1.gossip.features.find

import dev.vmd1.gossip.protocol.Envelope
import dev.vmd1.gossip.protocol.MessageType
import dev.vmd1.gossip.transport.EnvelopeHandler
import dev.vmd1.gossip.transport.MessageRouter
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
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
 * Both halves of Find my device. **Receiving** `device.ring` (see `schema/message-types.md`): a paired device asks this one to ring at
 * full volume so it can be found, or to stop. One-shot trigger, not persistent state, so no resync
 * loop — but it must be idempotent: `start` while already ringing is a no-op, `stop` while silent
 * is a no-op, and a duplicate/late `start` (identified by its per-attempt `ringId`, kept in a
 * bounded recently-handled cache, same pattern as `media.command`'s `commandId`) can never
 * restart a ring the user already stopped. Rings stop on their own after [autoStopMs].
 *
 * Whenever this device starts or stops ringing — for any reason: a `stop` message, the auto-stop, or the
 * local Stop notification — it reports `device.ring_state` back to whoever started the ring, so that
 * device's ring button can show "ringing" and clear again. **Sending**: [toggleRing] starts or stops a
 * ring on a peer and tracks which peers are ringing in [ringingPeers]; a peer's entry also expires after
 * [PEER_RINGING_EXPIRY_MS] (just past the auto-stop) as the self-healing backstop if a `ring_state`
 * report is ever lost.
 */
class RingManager(
    private val messageRouter: MessageRouter,
    private val ringer: Ringer,
    private val scope: CoroutineScope,
    private val autoStopMs: Long = AUTO_STOP_MS,
    /** Called whenever ringing starts/stops, so the UI layer can show/remove a "Stop" notification. */
    private val onRingingChanged: (ringing: Boolean) -> Unit = {},
    private val selfId: String = "",
    private val send: (Envelope) -> Unit = {}
) {
    private val handler = EnvelopeHandler { onEnvelope(it) }
    private val stateHandler = EnvelopeHandler { onRingState(it) }
    /** Who started the ring currently playing here — the device `ring_state` reports go to. */
    private var requesterId: String? = null

    private val _ringingPeers = MutableStateFlow<Set<String>>(emptySet())
    /** Peers this device has asked to ring and that haven't reported stopping (or expired). */
    val ringingPeers: StateFlow<Set<String>> = _ringingPeers.asStateFlow()
    private val peerExpiry = HashMap<String, Job>()
    private val recentRingIds = object : LinkedHashMap<String, Unit>(16, 0.75f, false) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Unit>?) = size > RECENT_CACHE_SIZE
    }
    private var autoStopJob: Job? = null

    @Volatile var isRinging = false
        private set

    fun start() {
        messageRouter.register(MessageType.DEVICE_RING, handler)
        messageRouter.register(MessageType.DEVICE_RING_STATE, stateHandler)
    }
    fun shutdown() {
        messageRouter.unregister(handler); messageRouter.unregister(stateHandler); stopRinging()
        peerExpiry.values.forEach { it.cancel() }; peerExpiry.clear()
    }

    private fun onEnvelope(envelope: Envelope) {
        val action = envelope.payload["action"]?.jsonPrimitive?.contentOrNull ?: return
        val ringId = envelope.payload["ringId"]?.jsonPrimitive?.contentOrNull ?: return
        when (action) {
            "start" -> synchronized(this) {
                if (recentRingIds.put(ringId, Unit) != null) return  // duplicate / late redelivery
                if (isRinging) return
                isRinging = true
                requesterId = envelope.senderId
                ringer.start()
                onRingingChanged(true)
                reportState(true)
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
        reportState(false)
        requesterId = null
    }

    private fun reportState(ringing: Boolean) {
        val to = requesterId ?: return
        send(Envelope(type = MessageType.DEVICE_RING_STATE, senderId = selfId, recipientId = to, payload = buildJsonObject {
            put("ringing", JsonPrimitive(ringing))
        }))
    }

    // ---- Sending ----

    /** Presses the ring button for [deviceId]: stops it if it's ringing, otherwise starts a ring. */
    fun toggleRing(deviceId: String) {
        val stopping = deviceId in _ringingPeers.value
        send(Envelope(type = MessageType.DEVICE_RING, senderId = selfId, recipientId = deviceId, payload = payload(if (stopping) "stop" else "start")))
        setPeerRinging(deviceId, !stopping)
    }

    private fun onRingState(envelope: Envelope) {
        val ringing = envelope.payload["ringing"]?.jsonPrimitive?.contentOrNull?.toBooleanStrictOrNull() ?: return
        setPeerRinging(envelope.senderId, ringing)
    }

    @Synchronized
    private fun setPeerRinging(deviceId: String, ringing: Boolean) {
        peerExpiry.remove(deviceId)?.cancel()
        if (ringing) {
            _ringingPeers.value = _ringingPeers.value + deviceId
            peerExpiry[deviceId] = scope.launch { delay(PEER_RINGING_EXPIRY_MS); setPeerRinging(deviceId, false) }
        } else {
            _ringingPeers.value = _ringingPeers.value - deviceId
        }
    }

    companion object {
        const val AUTO_STOP_MS = 30_000L
        const val PEER_RINGING_EXPIRY_MS = 35_000L
        private const val RECENT_CACHE_SIZE = 64

        fun payload(action: String, ringId: String = java.util.UUID.randomUUID().toString()) = buildJsonObject {
            put("action", JsonPrimitive(action))
            put("ringId", JsonPrimitive(ringId))
        }
    }
}
