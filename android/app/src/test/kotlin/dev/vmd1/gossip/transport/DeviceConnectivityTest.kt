package dev.vmd1.gossip.transport

import org.junit.Assert.assertEquals
import org.junit.Test

class DeviceConnectivityTest {
    @Test
    fun `direct beats mesh beats none`() {
        assertEquals(Connectivity.DIRECT, DeviceConnectivity.classify("a", setOf("a"), setOf("a")))
        assertEquals(Connectivity.MESH, DeviceConnectivity.classify("b", setOf("a"), setOf("b")))
        assertEquals(Connectivity.NONE, DeviceConnectivity.classify("c", setOf("a"), setOf("b")))
    }

    @Test
    fun `mesh reachable means heard recently, not direct, and not ourselves`() {
        val now = 1_000_000L
        val heard = mapOf(
            "fresh" to now - 10_000, "stale" to now - DeviceConnectivity.MESH_TTL_MS - 1,
            "direct" to now - 5_000, "me" to now - 1_000, "edge" to now - DeviceConnectivity.MESH_TTL_MS + 1
        )
        assertEquals(setOf("fresh", "edge"), DeviceConnectivity.meshReachable(heard, setOf("direct"), "me", now))
    }

    @Test
    fun `a device that becomes direct stops counting as mesh, and expires once quiet`() {
        val heard = mapOf("t" to 0L)
        assertEquals(setOf("t"), DeviceConnectivity.meshReachable(heard, emptySet(), "me", 60_000))
        assertEquals(emptySet<String>(), DeviceConnectivity.meshReachable(heard, setOf("t"), "me", 60_000))
        assertEquals(emptySet<String>(), DeviceConnectivity.meshReachable(heard, emptySet(), "me", 200_000))
    }
}
