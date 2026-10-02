package dev.vmd1.gossip.transport

/** How this device reaches a paired device right now — drives the green / blue / grey device icon. */
enum class Connectivity {
    /** A live connection straight to that device. */
    DIRECT,
    /** No direct connection, but it was heard from recently through another device (the mesh relays
     *  every broadcast, so its periodic updates still arrive). */
    MESH,
    NONE
}

object DeviceConnectivity {
    /** How long after the last message from a device it still counts as reachable over the mesh. Devices
     *  broadcast something at least every 60s (`battery.update`, `dnd.update`, ...), so this tolerates two
     *  missed rounds. */
    const val MESH_TTL_MS = 150_000L

    /** Devices not directly connected that were heard from within [MESH_TTL_MS]. */
    fun meshReachable(
        lastHeard: Map<String, Long>,
        directIds: Set<String>,
        selfId: String,
        now: Long,
        ttlMs: Long = MESH_TTL_MS
    ): Set<String> =
        lastHeard.filter { (id, at) -> id != selfId && id !in directIds && now - at < ttlMs }.keys

    fun classify(deviceId: String, directIds: Set<String>, meshIds: Set<String>): Connectivity = when {
        deviceId in directIds -> Connectivity.DIRECT
        deviceId in meshIds -> Connectivity.MESH
        else -> Connectivity.NONE
    }
}
