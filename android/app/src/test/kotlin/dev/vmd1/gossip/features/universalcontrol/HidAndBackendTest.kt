package dev.vmd1.gossip.features.universalcontrol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class HidAndBackendTest {
    @Test fun mouseReportLayout() {
        assertArrayEquals(byteArrayOf(0x05, 0x0a, 0x00, 0xfb.toByte(), 0xff.toByte(), 1, 0xff.toByte()), HidReports.mouseReport(5, 10, -5, 1, -1))
        assertEquals(7, HidReports.mouseReport(0, 0, 0).size)
        // clamped, never wrapped
        assertArrayEquals(byteArrayOf(0, 0xff.toByte(), 0x7f, 0x01, 0x80.toByte(), 127, 0x81.toByte()), HidReports.mouseReport(0, 99999, -99999, 500, -500))
    }

    @Test fun keyboardReportAndRollover() {
        assertArrayEquals(byteArrayOf(2, 0, 4, 5, 0, 0, 0, 0), HidReports.keyboardReport(2, listOf(4, 5)))
        assertEquals(6, HidReports.keyboardReport(0, (4..20).toList()).drop(2).count { it.toInt() != 0 })
        assertArrayEquals(ByteArray(8), HidReports.keyboardReport(0, listOf(0xE0, 0x01))) // modifier usages / invalid never occupy slots
    }

    @Test fun scrcpyFraming() {
        val create = HidReports.create(7, "ab", byteArrayOf(1, 2, 3), vendor = 0x18d1, product = 0x4e00)
        assertArrayEquals(byteArrayOf(12, 0, 7, 0x18, 0xd1.toByte(), 0x4e, 0x07, 2, 'a'.code.toByte(), 'b'.code.toByte(), 0, 3, 1, 2, 3), create)
        assertArrayEquals(byteArrayOf(13, 0, 7, 0, 2, 9, 9), HidReports.input(7, byteArrayOf(9, 9)))
        assertArrayEquals(byteArrayOf(14, 0, 7), HidReports.destroy(7))
        assertArrayEquals(byteArrayOf(1, 0, 0, 0, 2, 'h'.code.toByte(), 'i'.code.toByte()), HidReports.injectText("hi"))
        val paste = HidReports.pasteText("é")
        assertEquals(9, paste[0].toInt()); assertEquals(1, paste[9].toInt()); assertEquals(2, paste[13].toInt())
    }

    private class Recorder { val msgs = mutableListOf<ByteArray>(); fun type(i: Int) = msgs[i][0].toInt() }

    private fun backend(r: Recorder) = UhidInputBackend({ r.msgs.add(it) }, sleep = {})
    private val display = ControlDisplayInfo(2000, 1200, 1, 0)

    @Test fun inputIsIgnoredUntilEnteredAndEnterIsIdempotent() {
        val r = Recorder(); val b = backend(r)
        b.mouseMove(5, 5); b.key(4, true, 0); b.buttons(1)
        assertTrue(r.msgs.isEmpty())
        b.enter(ControlEdge.LEFT, 32768, display)
        assertEquals(listOf(12, 12), r.msgs.take(2).map { it[0].toInt() }) // mouse + keyboard created
        val afterFirst = r.msgs.size
        b.enter(ControlEdge.LEFT, 32768, display)                          // re-enter: no second create
        assertEquals(2, r.msgs.count { it[0].toInt() == 12 })
        assertTrue(r.msgs.size > afterFirst)
        // slam then walk to y = 0.5 * 1199
        val moves = r.msgs.filter { it[0].toInt() == 13 }.map { it.drop(5).toByteArray() }
        assertArrayEquals(HidReports.mouseReport(0, -32767, -32767), moves[0])
        assertArrayEquals(HidReports.mouseReport(0, 0, 599), moves[1])
    }

    @Test fun navigationActionsAreScrcpyKeycodesAndNotificationPanel() {
        val r = Recorder(); val b = backend(r)
        b.action(ControlAction.HOME)
        // one write holding two INJECT_KEYCODE messages (down, up): [0][action][keycode u32][repeat u32][meta u32]
        val down = byteArrayOf(0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0)
        val up = byteArrayOf(0, 1, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0)
        assertArrayEquals(down + up, r.msgs[0])
        b.action(ControlAction.BACK); b.action(ControlAction.APP_SWITCH)
        assertEquals(4, r.msgs[1][5].toInt()); assertEquals(187, r.msgs[2][5].toInt() and 0xff)
        r.msgs.clear()
        b.action(ControlAction.NOTIFICATIONS)
        assertArrayEquals(byteArrayOf(5), r.msgs.single())
    }

    @Test fun leaveReleasesButKeepsTheDevicesUntilDestroyed() {
        val r = Recorder(); val b = backend(r)
        b.enter(ControlEdge.RIGHT, 0, display)
        b.buttons(1); b.key(4, true, 2)
        r.msgs.clear()
        b.leave()
        assertEquals(listOf(13, 13), r.msgs.map { it[0].toInt() })            // mouse + keyboard released, nothing destroyed
        assertArrayEquals(HidReports.mouseReport(0, 0, 0), r.msgs[0].drop(5).toByteArray())
        assertArrayEquals(ByteArray(8), r.msgs[1].drop(5).toByteArray())
        r.msgs.clear(); b.leave()
        assertTrue(r.msgs.isEmpty())                                          // idempotent
        b.destroyDevices()
        assertEquals(listOf(14, 14), r.msgs.map { it[0].toInt() })
        r.msgs.clear(); b.destroyDevices()
        assertTrue(r.msgs.isEmpty())                                          // idempotent
    }

    @Test fun reEnteringBeforeTheDevicesAreDestroyedReusesThem() {
        val r = Recorder(); val b = backend(r)
        b.enter(ControlEdge.LEFT, 100, display); b.leave()
        assertEquals(2, r.msgs.count { it[0].toInt() == 12 })
        r.msgs.clear()
        b.enter(ControlEdge.LEFT, 100, display)
        assertEquals("no second create: re-entry skips the slow device creation", 0, r.msgs.count { it[0].toInt() == 12 })
        assertTrue(r.msgs.any { it[0].toInt() == 13 })                        // but the cursor is placed again
        // after a destroy it has to create them again
        b.leave(); b.destroyDevices(); r.msgs.clear()
        b.enter(ControlEdge.LEFT, 100, display)
        assertEquals(2, r.msgs.count { it[0].toInt() == 12 })
    }

    @Test fun strayInputAfterLeaveIsIgnoredWhileTheDevicesAreStillAlive() {
        val r = Recorder(); val b = backend(r)
        b.enter(ControlEdge.LEFT, 100, display); b.leave(); r.msgs.clear()
        b.mouseMove(50, 50); b.buttons(1); b.scroll(0, 120); b.key(4, true, 0)
        assertTrue("a late frame must not move the cursor on a device the Mac has left", r.msgs.isEmpty())
    }

    @Test fun devicesAreNeverDestroyedWhileTheCursorIsOnThem() {
        val r = Recorder(); val b = backend(r)
        b.enter(ControlEdge.TOP, 0, display); r.msgs.clear()
        b.destroyDevices()                                                    // a late grace timer must not pull them out
        assertTrue(r.msgs.isEmpty())
        b.buttons(1); r.msgs.clear()
        b.close()
        assertEquals(listOf(13, 14, 14), r.msgs.map { it[0].toInt() })        // closing releases the held button, then destroys both
    }

    @Test fun duplicateStateIsNotAnEvent() {
        val r = Recorder(); val b = backend(r)
        b.enter(ControlEdge.TOP, 0, display); r.msgs.clear()
        b.buttons(1); b.buttons(1)
        b.key(4, true, 0); b.key(4, true, 0)
        assertEquals(2, r.msgs.size)
        b.key(4, false, 0); b.key(4, false, 0)
        assertEquals(3, r.msgs.size)
    }

    @Test fun scrollAccumulatesFractionsOfANotch() {
        val r = Recorder(); val b = backend(r)
        b.enter(ControlEdge.TOP, 0, display); r.msgs.clear()
        b.scroll(0, 50); b.scroll(0, 50)
        assertTrue(r.msgs.isEmpty())
        b.scroll(0, 30)
        assertEquals(1, r.msgs.size)
        assertEquals(1, r.msgs[0][5 + 5].toInt()) // wheel byte
        b.scroll(-240, 0)
        assertEquals((-2).toByte(), r.msgs[1][5 + 6])
    }

    @Test fun textUsesInjectForAsciiAndClipboardPasteOtherwise() {
        val r = Recorder(); val b = backend(r)
        b.text("hello"); b.text("héllo")
        assertEquals(listOf(1, 9), r.msgs.map { it[0].toInt() })
    }
}
