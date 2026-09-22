package com.connect.features.notifications

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ReplyActionSelectorTest {
    @Test
    fun `returns index of first action with a remote input`() {
        assertEquals(1, ReplyActionSelector.findReplyActionIndex(listOf(0, 1, 0)))
    }

    @Test
    fun `returns first matching index when multiple actions carry remote inputs`() {
        assertEquals(0, ReplyActionSelector.findReplyActionIndex(listOf(2, 1)))
    }

    @Test
    fun `returns null when no action carries a remote input`() {
        assertNull(ReplyActionSelector.findReplyActionIndex(listOf(0, 0, 0)))
    }

    @Test
    fun `returns null for an empty action list`() {
        assertNull(ReplyActionSelector.findReplyActionIndex(emptyList()))
    }
}
