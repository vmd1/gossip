package com.connect.features.dnd

import com.connect.protocol.Envelope
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject

/** Payload for `dnd.update`: reports that the sender's own DND state changed. */
@Serializable
data class DndUpdatePayload(
    val sourceDeviceId: String,
    val enabled: Boolean
) {
    fun toJsonObject(): JsonObject = Envelope.json.encodeToJsonElement(serializer(), this) as JsonObject

    companion object {
        fun fromJsonObject(obj: JsonObject): DndUpdatePayload = Envelope.json.decodeFromJsonElement(serializer(), obj)
    }
}

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
