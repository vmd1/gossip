package dev.vmd1.gossip.transport

import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import org.junit.Test
import org.junit.Assert.assertEquals

class NewPeerFlowTest {
    @Test
    fun `second peer connecting while first is up emits only the new peer`() = runTest {
        val emitted = flowOf(setOf("tablet"), setOf("tablet", "mac")).newlyConnectedPeers().toList()
        assertEquals(listOf(setOf("tablet"), setOf("mac")), emitted)
    }

    @Test
    fun `repeats and departures emit nothing, a reconnect emits again`() = runTest {
        val emitted = flowOf(
            setOf("a"), setOf("a"), emptySet(), setOf("a")
        ).newlyConnectedPeers().toList()
        assertEquals(listOf(setOf("a"), setOf("a")), emitted)
    }
}
