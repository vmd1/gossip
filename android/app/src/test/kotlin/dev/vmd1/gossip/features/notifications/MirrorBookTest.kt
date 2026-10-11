package dev.vmd1.gossip.features.notifications

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MirrorBookTest {
    @Test
    fun syncRemovesWhatTheSenderNoLongerHasOnceOldEnough() {
        val book = MirrorBook()
        book.recordShown("phone|old", 0)
        book.recordShown("phone|kept", 0)
        book.recordShown("phone|fresh", 55_000)
        assertEquals(listOf("phone|old"), book.applySync("phone|", setOf("phone|kept"), 60_000))
    }

    @Test
    fun syncOnlyTouchesTheSendersNotificationsAndIsIdempotent() {
        val book = MirrorBook()
        book.recordShown("phone|a", 0)
        book.recordShown("tablet|b", 0)
        assertEquals(listOf("phone|a"), book.applySync("phone|", emptySet(), 60_000))
        assertTrue(book.applySync("phone|", emptySet(), 60_000).isEmpty())
        assertEquals(listOf("tablet|b"), book.applySync("tablet|", emptySet(), 60_000))
    }

    @Test
    fun aPostArrivingAfterItsRemovalIsStaleButARepostIsNot() {
        val book = MirrorBook()
        book.recordRemoval("phone|a", 5_000)
        assertTrue(book.isStale("phone|a", 4_000))
        assertTrue(book.isStale("phone|a", 5_000))
        assertFalse(book.isStale("phone|a", 6_000))
        assertFalse(book.isStale("phone|other", 1))
    }

    @Test
    fun aRemovalForgetsTheShownNotification() {
        val book = MirrorBook()
        book.recordShown("phone|a", 0)
        book.recordRemoval("phone|a", 10)
        assertTrue(book.applySync("phone|", emptySet(), 60_000).isEmpty())
    }
}
