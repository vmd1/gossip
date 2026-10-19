package dev.vmd1.gossip.features.clipboard

import dev.vmd1.gossip.crypto.FakeSharedPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ClipboardHistoryStoreTest {
    private fun store(enabled: Boolean = true) = ClipboardHistoryStore(FakeSharedPreferences()).also { it.setEnabled(enabled) }

    @Test
    fun `disabled store records nothing`() {
        val s = store(enabled = false)
        s.record("hello", remote = false)
        assertTrue(s.entries.value.isEmpty())
    }

    @Test
    fun `recopy moves to top without duplicating`() {
        val s = store()
        s.record("a", false); s.record("b", false); s.record("a", false)
        assertEquals(listOf("a", "b"), s.entries.value.map { it.text })
        s.record("a", false)
        assertEquals(2, s.entries.value.size)
    }

    @Test
    fun `pins survive trim and sort first`() {
        val s = store()
        s.record("keep", false)
        s.togglePin(s.entries.value[0].id)
        repeat(ClipboardHistoryStore.MAX_UNPINNED + 5) { s.record("item $it", false) }
        assertEquals(ClipboardHistoryStore.MAX_UNPINNED, s.entries.value.count { !it.pinned })
        assertEquals("keep", s.filtered("").first().text)
    }

    @Test
    fun `search ignores blanks and turning off wipes`() {
        val s = store()
        s.record("Hello World", true); s.record("   ", false)
        assertEquals(listOf("Hello World"), s.filtered("world").map { it.text })
        s.setEnabled(false)
        assertTrue(s.entries.value.isEmpty())
    }
}
