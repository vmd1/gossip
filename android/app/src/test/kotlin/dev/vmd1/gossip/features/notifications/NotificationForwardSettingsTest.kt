package dev.vmd1.gossip.features.notifications

import dev.vmd1.gossip.crypto.FakeSharedPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationForwardSettingsTest {
    @Test
    fun `every app is allowed by default`() {
        val settings = NotificationForwardSettings(FakeSharedPreferences())
        assertTrue(settings.isAllowed("com.example.anything"))
        assertTrue(settings.blocked.value.isEmpty())
    }

    @Test
    fun `blocking is per app and persists`() {
        val prefs = FakeSharedPreferences()
        val settings = NotificationForwardSettings(prefs)
        settings.setAllowed("com.a", false)
        assertFalse(settings.isAllowed("com.a"))
        assertTrue(settings.isAllowed("com.b"))
        assertEquals(setOf("com.a"), settings.blocked.value)

        val reloaded = NotificationForwardSettings(prefs)
        assertFalse(reloaded.isAllowed("com.a"))
        assertTrue(reloaded.isAllowed("com.b"))

        reloaded.setAllowed("com.a", true)
        assertTrue(NotificationForwardSettings(prefs).isAllowed("com.a"))
    }

    @Test
    fun `repeating a setting is a no-op and allow-all clears every block`() {
        val settings = NotificationForwardSettings(FakeSharedPreferences())
        settings.setAllowed("com.a", false); settings.setAllowed("com.a", false)
        settings.setAllowed("com.b", false)
        assertEquals(setOf("com.a", "com.b"), settings.blocked.value)
        settings.setAllowed("com.c", true)
        assertEquals(setOf("com.a", "com.b"), settings.blocked.value)
        settings.setAllAllowed()
        assertTrue(settings.blocked.value.isEmpty())
        assertTrue(settings.isAllowed("com.a"))
    }
}
