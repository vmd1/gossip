package dev.vmd1.gossip.transport

import dev.vmd1.gossip.protocol.Envelope
import java.util.concurrent.CopyOnWriteArrayList

/** A handler that reacts to envelopes whose `type` starts with a registered namespace prefix. */
fun interface EnvelopeHandler {
    fun onEnvelope(envelope: Envelope)
}

/**
 * Dispatches decoded envelopes to handlers registered by `type` prefix (e.g. `"presence."`
 * or an exact type like `"handshake.hello"`), so later feature modules (calls, notifications,
 * clipboard, file transfer, ...) can register their own handlers without touching
 * [dev.vmd1.gossip.transport.TransportManager] itself.
 */
class MessageRouter(
    /** Per-device feature toggles: an envelope whose feature is off on this device is never delivered. */
    private val isMessageAllowed: (type: String) -> Boolean = { true }
) {
    private val handlers = CopyOnWriteArrayList<Pair<String, EnvelopeHandler>>()

    /** Registers [handler] for every envelope whose `type` starts with [prefix]. */
    fun register(prefix: String, handler: EnvelopeHandler) {
        handlers.add(prefix to handler)
    }

    fun unregister(handler: EnvelopeHandler) {
        handlers.removeAll { it.second === handler }
    }

    /** Delivers [envelope] to every handler whose prefix matches. Never throws. */
    fun dispatch(envelope: Envelope) {
        if (!isMessageAllowed(envelope.type)) return
        for ((prefix, handler) in handlers) {
            if (envelope.type.startsWith(prefix)) {
                runCatching { handler.onEnvelope(envelope) }
            }
        }
    }
}
