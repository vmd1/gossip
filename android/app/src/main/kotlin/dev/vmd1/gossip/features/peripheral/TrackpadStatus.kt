package dev.vmd1.gossip.features.peripheral

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.jsonPrimitive

/** Turns the Mac's `trackpad.status` slot (see `schema/message-types.md`) into what to tell the user, or `null` if all is well. */
object TrackpadStatus {
    const val SLOT = "trackpad.status"

    fun problem(macName: String, connected: Boolean, status: JsonElement?): String? {
        if (!connected) return "$macName isn't connected. Check that Gossip is running on it and on the same network."
        val s = status as? JsonObject
            ?: return "Can't tell whether $macName accepts trackpad input. Update Gossip on the Mac."
        if (s["enabled"]?.jsonPrimitive?.booleanOrNull == false) {
            return "“Phone as trackpad & keyboard” is turned off on $macName. Turn it on in Gossip → Settings on the Mac."
        }
        if (s["accessibility"]?.jsonPrimitive?.booleanOrNull == false) {
            return "Gossip on $macName needs the Accessibility permission: System Settings → Privacy & Security → Accessibility."
        }
        return null
    }
}
