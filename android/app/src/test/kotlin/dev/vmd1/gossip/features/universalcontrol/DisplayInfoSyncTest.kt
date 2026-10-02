package dev.vmd1.gossip.features.universalcontrol

import dev.vmd1.gossip.protocol.Envelope
import dev.vmd1.gossip.protocol.MessageType
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DisplayInfoSyncTest {
    @Test
    fun `resync broadcasts the current size every time it is called`() = runTest {
        val sent = mutableListOf<Envelope>()
        val scope = TestScope(StandardTestDispatcher(testScheduler))
        val sync = DisplayInfoSync("phone", { sent += it }, scope) { DisplaySize(1080, 2400, 0) }
        sync.resync(); sync.resync()
        scope.advanceUntilIdle()
        assertEquals(2, sent.size)
        val e = sent[0]
        assertEquals(MessageType.DISPLAY_INFO, e.type)
        assertTrue(e.broadcast)
        assertEquals("1080", e.payload["width"]!!.jsonPrimitive.content)
        assertEquals("2400", e.payload["height"]!!.jsonPrimitive.content)
        assertEquals(sent[0].payload, sent[1].payload)
    }

    @Test
    fun `nothing is sent when the size cannot be read`() = runTest {
        val sent = mutableListOf<Envelope>()
        val scope = TestScope(StandardTestDispatcher(testScheduler))
        DisplayInfoSync("phone", { sent += it }, scope) { null }.resync()
        scope.advanceUntilIdle()
        assertTrue(sent.isEmpty())
    }
}
