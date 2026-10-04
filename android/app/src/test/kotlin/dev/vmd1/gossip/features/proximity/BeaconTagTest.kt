package dev.vmd1.gossip.features.proximity

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class BeaconTagTest {
    private fun hex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    @Test
    fun `tags match the shared vectors`() {
        var dir: File? = File("").absoluteFile
        while (dir != null && !File(dir, "schema/ble-beacon-vectors.json").exists()) dir = dir.parentFile
        val root = Json.parseToJsonElement(File(checkNotNull(dir), "schema/ble-beacon-vectors.json").readText()).jsonObject
        val key = hex(root["keyHex"]!!.jsonPrimitive.content)
        assertEquals(root["windowSeconds"]!!.jsonPrimitive.long, BeaconTag.WINDOW_SECONDS)
        for (c in root["cases"]!!.jsonArray) {
            val o = c.jsonObject
            assertArrayEquals(hex(o["tagHex"]!!.jsonPrimitive.content), BeaconTag.tag(key, o["window"]!!.jsonPrimitive.long))
        }
    }

    @Test
    fun `acceptable tags cover one window of skew and nothing else`() {
        val key = ByteArray(32) { 7 }
        val now = 1_700_000_000_000L
        val w = BeaconTag.window(now)
        val tags = BeaconTag.acceptableTags(key, now).map { it.toList() }
        assertEquals(3, tags.size)
        for (d in -1L..1L) assertTrue(tags.contains(BeaconTag.tag(key, w + d).toList()))
        assertFalse(tags.contains(BeaconTag.tag(key, w + 2).toList()))
        // An outsider with a different key matches nothing.
        val other = BeaconTag.acceptableTags(ByteArray(32) { 8 }, now).map { it.toList() }
        assertTrue(tags.intersect(other.toSet()).isEmpty())
        val left = BeaconTag.millisUntilNextWindow(now)
        assertTrue(left in 1..60_000)
    }
}
