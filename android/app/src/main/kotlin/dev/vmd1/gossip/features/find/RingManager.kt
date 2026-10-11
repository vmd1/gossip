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
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import uniffi.gossip_ffi.Outgoing
import uniffi.gossip_ffi.Ring as CoreRing
import uniffi.gossip_ffi.RingEffect

/** Plays (and stops) the actual alarm sound — behind an interface so [RingManager] is unit-testable without audio hardware. */
interface Ringer {
    fun start()
    fun stop()
}

/**
 * Both halves of Find my device. **Receiving** `device.ring` (see `schema/message-types.md`): a paired device asks this one to
 * ring at full volume so it can be found, or to stop. One-shot trigger, not persistent state, so no resync — but idempotent:
 * `start` while already ringing is a no-op, `stop` while silent is a no-op, and a duplicate/late `start` (identified by its
 * per-attempt `ringId`, kept in a bounded recently-handled cache) can never restart a ring the user already stopped. Rings
 * stop on their own after 30 s.
 *
 * Whenever this device starts or stops ringing — for any reason: a `stop` message, the auto-stop, or the local Stop
 * notification — it reports `device.ring_state` back to whoever started the ring, so that device's ring button can show
 * "ringing" and clear again. **Sending**: [toggleRing] starts or stops a ring on a peer and tracks which peers are ringing in
 * [ringingPeers]; a peer's entry also expires after 35 s as the self-healing backstop if a `ring_state` report is ever lost.
 *
 * All of that decision logic is the core's `Ring` (`desktop/core/src/features/ring.rs`), shared with every platform; this class
 * plays the alarm and drives the core's clock once a second.
 */
class RingManager(
    private val messageRouter: MessageRouter,
    private val ringer: Ringer,
    private val scope: CoroutineScope,
    /** Called whenever ringing starts/stops, so the UI layer can show/remove a "Stop" notification. */
    private val onRingingChanged: (ringing: Boolean) -> Unit = {},
    private val selfId: String = "",
    private val send: (Envelope) -> Unit = {},
    private val now: () -> Long = System::currentTimeMillis,
    private val tickMs: Long = 1_000
) {
    private val logic = CoreRing()
    private val handler = EnvelopeHandler { envelope ->
        synchronized(this) { runCatching { logic.onRing(envelope.senderId, envelope.payload.toString(), now()) }.getOrNull()?.let(::carryOut) }
    }
    private val stateHandler = EnvelopeHandler { envelope ->
        synchronized(this) { runCatching { logic.onRingState(envelope.senderId, envelope.payload.toString(), now()) }.getOrNull()?.let(::carryOut) }
    }
    private var tickJob: Job? = null

    private val _ringingPeers = MutableStateFlow<Set<String>>(emptySet())
    /** Peers this device has asked to ring and that haven't reported stopping (or expired). */
    val ringingPeers: StateFlow<Set<String>> = _ringingPeers.asStateFlow()

    @Volatile var isRinging = false
        private set

    fun start() {
        messageRouter.register(MessageType.DEVICE_RING, handler)
        messageRouter.register(MessageType.DEVICE_RING_STATE, stateHandler)
        tickJob?.cancel()
        tickJob = scope.launch { while (isActive) { delay(tickMs); tick() } }
    }

    fun shutdown() {
        messageRouter.unregister(handler); messageRouter.unregister(stateHandler)
        tickJob?.cancel(); tickJob = null
        stopRinging()
    }

    /** Silences the ring (also wired to the notification's Stop action). No-op when not ringing. */
    @Synchronized
    fun stopRinging() = carryOut(logic.stopRinging())

    /** Auto-stop and peer-entry expiry; driven once a second (and directly by tests). */
    @Synchronized
    fun tick() = carryOut(logic.tick(now()))

    /** Presses the ring button for [deviceId]: stops it if it's ringing, otherwise starts a ring. */
    @Synchronized
    fun toggleRing(deviceId: String) = carryOut(logic.toggle(deviceId, java.util.UUID.randomUUID().toString(), now()))

    private fun carryOut(effects: List<RingEffect>) {
        for (effect in effects) {
            when (effect) {
                is RingEffect.StartRinger -> { ringer.start(); onRingingChanged(true) }
                is RingEffect.StopRinger -> { ringer.stop(); onRingingChanged(false) }
                is RingEffect.Send -> send(effect.message.toEnvelope())
                // The "Stop" notification is shown from [onRingingChanged]; nothing else to show or close here.
                is RingEffect.ShowAlert, is RingEffect.CloseAlert, is RingEffect.PeersChanged -> Unit
            }
        }
        isRinging = logic.isRinging()
        val peers = logic.ringingPeers().toSet()
        if (peers != _ringingPeers.value) _ringingPeers.value = peers
    }

    private fun Outgoing.toEnvelope() = Envelope(
        type = kind, senderId = selfId, recipientId = recipient, payload = Json.parseToJsonElement(payloadJson) as JsonObject
    )

    companion object {
        const val AUTO_STOP_MS = 30_000L
        const val PEER_RINGING_EXPIRY_MS = 35_000L
    }
}
