package dev.vmd1.gossip.onboarding

import dev.vmd1.gossip.crypto.FakeSharedPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class OnboardingPreferencesTest {

    private lateinit var prefs: OnboardingPreferences

    @Before
    fun setUp() {
        prefs = OnboardingPreferences(FakeSharedPreferences())
    }

    @Test
    fun `isCompleted defaults to false`() {
        assertFalse(prefs.isCompleted)
    }

    @Test
    fun `isCompleted persists once set`() {
        prefs.isCompleted = true
        assertTrue(prefs.isCompleted)
    }

    @Test
    fun `preferredHotspotMechanismId defaults to null`() {
        assertNull(prefs.preferredHotspotMechanismId)
    }

    @Test
    fun `preferredHotspotMechanismId persists once set`() {
        prefs.preferredHotspotMechanismId = "shizuku_raw_aidl"
        assertEquals("shizuku_raw_aidl", prefs.preferredHotspotMechanismId)
    }

    @Test
    fun `preferredHotspotMechanismId can be cleared back to null`() {
        prefs.preferredHotspotMechanismId = "write_secure_settings"
        prefs.preferredHotspotMechanismId = null
        assertNull(prefs.preferredHotspotMechanismId)
    }

    @Test
    fun `separate instances backed by the same prefs see each other's writes`() {
        val backing = FakeSharedPreferences()
        val first = OnboardingPreferences(backing)
        val second = OnboardingPreferences(backing)

        first.isCompleted = true

        assertTrue(second.isCompleted)
    }
}
