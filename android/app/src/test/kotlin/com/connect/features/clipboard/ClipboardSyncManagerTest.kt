package com.connect.features.clipboard

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
}
