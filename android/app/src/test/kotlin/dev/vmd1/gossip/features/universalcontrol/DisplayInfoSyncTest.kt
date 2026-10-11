package dev.vmd1.gossip.features.universalcontrol

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DisplayInfoSyncTest {
    @Test
    fun `publish sets the control display slot to the current size`() {
        val published = mutableListOf<Pair<String, JsonElement?>>()
        val sync = DisplayInfoSync({ slot, value -> published += slot to value }) { DisplaySize(1080, 2400, 1) }
        sync.publish()
        val (slot, value) = published.single()
        assertEquals("control.display", slot)
        assertEquals("1080", value!!.jsonObject["width"]!!.jsonPrimitive.content)
        assertEquals("2400", value.jsonObject["height"]!!.jsonPrimitive.content)
        assertEquals("1", value.jsonObject["rotation"]!!.jsonPrimitive.content)
    }

    @Test
    fun `nothing is published when the size cannot be read`() {
        val published = mutableListOf<Pair<String, JsonElement?>>()
        DisplayInfoSync({ slot, value -> published += slot to value }) { null }.publish()
        assertTrue(published.isEmpty())
    }
}
