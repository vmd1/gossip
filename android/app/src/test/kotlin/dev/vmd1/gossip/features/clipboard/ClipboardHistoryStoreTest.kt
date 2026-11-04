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

    private fun imageStore(): Pair<ClipboardHistoryStore, java.io.File> {
        val dir = java.nio.file.Files.createTempDirectory("hist-img").toFile()
        return ClipboardHistoryStore(FakeSharedPreferences(), dir).also { it.setEnabled(true) } to dir
    }

    @Test
    fun `an image is stored and the same image moves to the top`() {
        val (s, dir) = imageStore()
        val a = byteArrayOf(1, 2, 3); val b = byteArrayOf(4, 5, 6)
        s.recordImage(a, 10, 20, false); s.recordImage(b, 1, 1, true); s.recordImage(a, 10, 20, false)
        assertEquals(2, s.entries.value.size)
        assertEquals("Image 10×20", s.entries.value[0].text)
        assertTrue(a.contentEquals(s.imageBytes(s.entries.value[0])))
        assertEquals(2, dir.listFiles()!!.size)
    }

    @Test
    fun `removing clearing and trimming delete image files`() {
        val (s, dir) = imageStore()
        repeat(ClipboardHistoryStore.MAX_UNPINNED + 3) { s.recordImage(byteArrayOf((it % 250).toByte(), (it / 250).toByte(), 9), 1, 1, false) }
        assertEquals(ClipboardHistoryStore.MAX_UNPINNED, dir.listFiles()!!.size)
        s.remove(s.entries.value[0].id)
        assertEquals(ClipboardHistoryStore.MAX_UNPINNED - 1, dir.listFiles()!!.size)
        s.clear()
        assertTrue(dir.listFiles()!!.isEmpty())
    }

    @Test
    fun `oversized images and a store without a folder skip images`() {
        val (s, dir) = imageStore()
        s.recordImage(ByteArray(ClipboardHistoryStore.MAX_IMAGE_BYTES + 1), 1, 1, false)
        assertTrue(s.entries.value.isEmpty() && dir.listFiles().orEmpty().isEmpty())
        val noDir = ClipboardHistoryStore(FakeSharedPreferences()).also { it.setEnabled(true) }
        noDir.recordImage(byteArrayOf(1), 1, 1, false)
        assertTrue(noDir.entries.value.isEmpty())
    }
}
