package dev.vmd1.gossip.features.screenmirror

import org.junit.Assert.assertArrayEquals
import org.junit.Test

class ScreenOffTest {
    /** KEYCODE_POWER toggles — it would turn an already-off screen back on — so the command must be SLEEP. */
    @Test
    fun `uses the sleep key, never the toggling power key`() {
        assertArrayEquals(arrayOf("input", "keyevent", "KEYCODE_SLEEP"), ScreenOff.COMMAND)
    }
}
