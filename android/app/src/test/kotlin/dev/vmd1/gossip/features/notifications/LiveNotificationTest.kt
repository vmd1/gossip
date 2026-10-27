package dev.vmd1.gossip.features.notifications

import android.app.Notification
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LiveNotificationTest {
    @Test fun `calls, timers, progress and Live Updates qualify`() {
        assertTrue(NotificationLiveInfo.qualifies(false, Notification.CATEGORY_CALL, 0, false, false))
        assertTrue(NotificationLiveInfo.qualifies(false, null, 100, false, false))
        assertTrue(NotificationLiveInfo.qualifies(false, null, 0, true, false))
        assertTrue(NotificationLiveInfo.qualifies(false, null, 0, false, true))
        assertTrue(NotificationLiveInfo.qualifies(true, null, 0, false, false))
    }

    @Test fun `a plain persistent notification does not`() {
        assertFalse(NotificationLiveInfo.qualifies(false, Notification.CATEGORY_SERVICE, 0, false, false))
        assertFalse(NotificationLiveInfo.qualifies(false, null, 0, false, false))
    }

    @Test fun `throttle sends changes and drops repeats within the interval`() {
        val throttle = LiveThrottle(minIntervalMs = 2_000)
        val sent = listOf(
            throttle.shouldSend("k", 0, "5 min away", 10, 100),      // first
            throttle.shouldSend("k", 500, "5 min away", 12, 100),    // +2%, same text: dropped
            throttle.shouldSend("k", 900, "5 min away", 16, 100),    // +6% since last send
            throttle.shouldSend("k", 1_000, "4 min away", 16, 100),  // text changed
            throttle.shouldSend("k", 1_200, "4 min away", 16, 100),  // nothing new
            throttle.shouldSend("k", 3_100, "4 min away", 16, 100),  // interval elapsed
        )
        assertEquals(listOf(true, false, true, true, false, true), sent)
    }

    @Test fun `a forgotten key sends again at once`() {
        val throttle = LiveThrottle()
        assertTrue(throttle.shouldSend("k", 0, "x", null, null))
        assertFalse(throttle.shouldSend("k", 10, "x", null, null))
        throttle.forget("k")
        assertTrue(throttle.shouldSend("k", 20, "x", null, null))
    }
}
