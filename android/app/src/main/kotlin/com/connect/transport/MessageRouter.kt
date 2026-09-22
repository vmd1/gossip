package com.connect.transport

import com.connect.protocol.Envelope
import java.util.concurrent.CopyOnWriteArrayList

/** A handler that reacts to envelopes whose `type` starts with a registered namespace prefix. */
fun interface EnvelopeHandler {
    fun onEnvelope(envelope: Envelope)
}

/**
 * Dispatches decoded envelopes to handlers registered by `type` prefix (e.g. `"presence."`
 * or an exact type like `"handshake.hello"`), so later feature modules (calls, notifications,
 * clipboard, file transfer, ...) can register their own handlers without touching
 * [com.connect.transport.TransportManager] itself.
 */
class MessageRouter {
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
        for ((prefix, handler) in handlers) {
            if (envelope.type.startsWith(prefix)) {
                runCatching { handler.onEnvelope(envelope) }
            }
        }
    }
}
