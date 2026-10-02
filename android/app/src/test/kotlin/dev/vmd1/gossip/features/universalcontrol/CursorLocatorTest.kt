package dev.vmd1.gossip.features.universalcontrol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CursorLocatorTest {
    @Test fun parsesTheSpritePosition() {
        assertEquals(Pair(388.774f, 360.5f), CursorLocator.parse("pos=(388.774,360.5)\n"))
        assertEquals(Pair(-3.5f, 0f), CursorLocator.parse("noise pos=(-3.5,0) more"))
        assertNull(CursorLocator.parse(""))
        assertNull(CursorLocator.parse(null))
        assertNull(CursorLocator.parse("pos=(abc,1)"))
    }

    @Test fun positionIsNullUntilCalibratedAndWhenUnreadable() {
        var dump: String? = "pos=(100.0,200.0)"
        val locator = CursorLocator { dump }
        assertNull("not calibrated yet", locator.position())
        assertTrue(locator.calibrate(Pair(1, 1)))
        assertEquals(Pair(1f, 1f), locator.position())
        dump = null
        assertNull("unreadable", locator.position())
    }

    @Test fun calibrationRemovesTheCursorHotspotOffset() {
        // At the entry point (0, 366) the sprite layer reads (-5.5, 360.5): the image's hotspot is (5.5, 5.5) off.
        var dump = "pos=(-5.5,360.5)"
        val locator = CursorLocator { dump }
        assertTrue(locator.calibrate(Pair(0, 366)))
        dump = "pos=(299.5,360.5)"
        assertEquals(Pair(305.0f, 366.0f), locator.position())
    }

    @Test fun calibrationFailsWithoutAReading() {
        val locator = CursorLocator { null }
        assertFalse(locator.calibrate(Pair(0, 0)))
        assertFalse(locator.calibrated)
    }
}
