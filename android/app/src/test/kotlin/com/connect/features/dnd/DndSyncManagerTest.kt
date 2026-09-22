package com.connect.features.dnd

import android.app.NotificationManager
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DndSyncManagerTest {

    @Test
    fun `INTERRUPTION_FILTER_ALL maps to disabled`() {
        assertFalse(DndSyncManager.interruptionFilterToEnabled(NotificationManager.INTERRUPTION_FILTER_ALL))
    }

    @Test
    fun `INTERRUPTION_FILTER_PRIORITY maps to enabled`() {
        assertTrue(DndSyncManager.interruptionFilterToEnabled(NotificationManager.INTERRUPTION_FILTER_PRIORITY))
    }

    @Test
    fun `INTERRUPTION_FILTER_NONE maps to enabled`() {
        assertTrue(DndSyncManager.interruptionFilterToEnabled(NotificationManager.INTERRUPTION_FILTER_NONE))
    }

    @Test
    fun `INTERRUPTION_FILTER_ALARMS maps to enabled`() {
        assertTrue(DndSyncManager.interruptionFilterToEnabled(NotificationManager.INTERRUPTION_FILTER_ALARMS))
    }

    @Test
    fun `unknown filter value maps to enabled (fail-safe toward reporting DND on)`() {
        assertTrue(DndSyncManager.interruptionFilterToEnabled(-1))
    }

    @Test
    fun `payload round-trips through json`() {
        val update = DndUpdatePayload(sourceDeviceId = "device-123", enabled = true)
        val decoded = DndUpdatePayload.fromJsonObject(update.toJsonObject())
        assertEquals(update, decoded)

        val set = DndSetPayload(enabled = false)
        val decodedSet = DndSetPayload.fromJsonObject(set.toJsonObject())
        assertEquals(set, decodedSet)
    }
}
