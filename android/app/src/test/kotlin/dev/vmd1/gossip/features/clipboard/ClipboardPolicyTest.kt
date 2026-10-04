package dev.vmd1.gossip.features.clipboard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files

class ClipboardPolicyTest {
    @Test
    fun `text is capped by encoded size`() {
        assertTrue(ClipboardPolicy.textAllowed("hello"))
        assertTrue(ClipboardPolicy.textAllowed("a".repeat(ClipboardPolicy.MAX_TEXT_BYTES)))
        assertFalse(ClipboardPolicy.textAllowed("a".repeat(ClipboardPolicy.MAX_TEXT_BYTES + 1)))
        // 3 bytes per character: well under the character count limit but over the byte limit
        assertFalse(ClipboardPolicy.textAllowed("€".repeat(ClipboardPolicy.MAX_TEXT_BYTES / 2)))
    }

    @Test
    fun `images are capped by bytes and decoded dimensions`() {
        assertTrue(ClipboardPolicy.imageBytesAllowed(1))
        assertTrue(ClipboardPolicy.imageBytesAllowed(ClipboardPolicy.MAX_IMAGE_BYTES))
        assertFalse(ClipboardPolicy.imageBytesAllowed(0))
        assertFalse(ClipboardPolicy.imageBytesAllowed(ClipboardPolicy.MAX_IMAGE_BYTES + 1))
        assertTrue(ClipboardPolicy.imageDimensionsAllowed(4000, 3000))
        assertFalse(ClipboardPolicy.imageDimensionsAllowed(20000, 20000))
        assertFalse(ClipboardPolicy.imageDimensionsAllowed(0, 100))
        assertFalse(ClipboardPolicy.imageDimensionsAllowed(-1, 100))
    }

    @Test
    fun `pruning keeps only the named file`() {
        val dir = Files.createTempDirectory("clip").toFile()
        val keep = dir.resolve("keep.png").apply { writeText("k") }
        dir.resolve("old1.png").writeText("x"); dir.resolve("old2.png").writeText("y")
        ClipboardPolicy.pruneCache(dir, keep)
        assertEquals(listOf("keep.png"), dir.list()!!.toList())
        ClipboardPolicy.pruneCache(dir)
        assertTrue(dir.list()!!.isEmpty())
        ClipboardPolicy.pruneCache(dir.resolve("missing")) // no directory: harmless
        dir.deleteRecursively()
    }
}
