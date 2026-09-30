package dev.vmd1.gossip.features.clipboard

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ClipboardSyncManagerTest {

    @Test
    fun `sends when value differs from last remote-set value`() {
        assertTrue(ClipboardSyncManager.shouldSend(newValue = "hello", lastRemoteSetValue = "goodbye"))
    }

    @Test
    fun `sends when there is no last remote-set value yet`() {
        assertTrue(ClipboardSyncManager.shouldSend(newValue = "hello", lastRemoteSetValue = null))
    }

    @Test
    fun `suppresses send when value matches last remote-set value`() {
        assertFalse(ClipboardSyncManager.shouldSend(newValue = "hello", lastRemoteSetValue = "hello"))
    }

    @Test
    fun `suppresses send when value matches last sent value (periodic resync of a locally-owned value)`() {
        // Regression test for #29: without checking lastSentValue too, a resync tick would
        // re-broadcast a locally-originated clipboard value forever, since lastRemoteSetValue
        // (only set on receiving a peer's update) never matches it.
        assertFalse(
            ClipboardSyncManager.shouldSend(newValue = "hello", lastRemoteSetValue = null, lastSentValue = "hello")
        )
    }

    @Test
    fun `sends when value differs from both last remote-set and last sent value`() {
        assertTrue(
            ClipboardSyncManager.shouldSend(newValue = "hello", lastRemoteSetValue = "goodbye", lastSentValue = "earlier")
        )
    }

    @Test
    fun `sends image when data differs from last remote-set image data`() {
        assertTrue(ClipboardSyncManager.shouldSendImage(byteArrayOf(1, 2), byteArrayOf(3, 4)))
    }

    @Test
    fun `sends image when there is no last remote-set image data yet`() {
        assertTrue(ClipboardSyncManager.shouldSendImage(byteArrayOf(1), null))
    }

    @Test
    fun `suppresses image send when data matches last remote-set image data`() {
        val data = byteArrayOf(1, 2, 3)
        assertFalse(ClipboardSyncManager.shouldSendImage(data, data.copyOf()))
    }

    @Test
    fun `suppresses image send when data matches last sent image data`() {
        val data = byteArrayOf(1, 2, 3)
        assertFalse(ClipboardSyncManager.shouldSendImage(data, null, data.copyOf()))
    }

    @Test
    fun `sends image when data differs from both last remote-set and last sent image data`() {
        assertTrue(ClipboardSyncManager.shouldSendImage(byteArrayOf(9), byteArrayOf(1), byteArrayOf(2)))
    }
}
