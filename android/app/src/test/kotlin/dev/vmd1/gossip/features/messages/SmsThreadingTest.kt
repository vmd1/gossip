package dev.vmd1.gossip.features.messages

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SmsThreadingTest {
    @Test fun `groups rows into threads newest first with unread counts`() {
        val rows = listOf(
            SmsRow(1, 10, "+1555", "old", 100, 1, true),
            SmsRow(2, 10, "+1555", "new", 300, 1, false),
            SmsRow(3, 11, "+1666", "mine", 200, 2, true),
            SmsRow(4, 10, "+1555", "also new", 250, 1, false),
        )
        val threads = SmsThreading.group(rows)
        assertEquals(listOf("10", "11"), threads.map { it.id })
        assertEquals("new", threads[0].snippet); assertEquals(2, threads[0].unread)
        assertTrue(threads[1].outgoing); assertEquals(0, threads[1].unread)
    }

    @Test fun `normalizes numbers across formats`() {
        assertEquals(SmsThreading.normalize("+1 (555) 123-4567"), SmsThreading.normalize("5551234567"))
        assertEquals("mum", SmsThreading.normalize(" Mum "))
    }

    @Test fun `only plausible numbers are sendable`() {
        assertTrue(SmsThreading.isPlausibleAddress("+44 7700 900123"))
        assertFalse(SmsThreading.isPlausibleAddress("AMAZON"))
        assertFalse(SmsThreading.isPlausibleAddress("12"))
        assertFalse(SmsThreading.isPlausibleAddress("5551234; DROP"))
    }
}
