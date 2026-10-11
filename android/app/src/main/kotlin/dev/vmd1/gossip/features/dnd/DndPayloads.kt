package dev.vmd1.gossip.features.dnd

import dev.vmd1.gossip.protocol.Envelope
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject

/** Payload for `dnd.set`: requests the recipient change its own DND state. */
@Serializable
data class DndSetPayload(
    val enabled: Boolean
) {
    fun toJsonObject(): JsonObject = Envelope.json.encodeToJsonElement(serializer(), this) as JsonObject

    companion object {
        fun fromJsonObject(obj: JsonObject): DndSetPayload = Envelope.json.decodeFromJsonElement(serializer(), obj)
    }
}
