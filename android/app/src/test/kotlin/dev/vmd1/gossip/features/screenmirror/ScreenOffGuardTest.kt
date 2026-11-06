package dev.vmd1.gossip.features.screenmirror

import dev.vmd1.gossip.crypto.FakeSharedPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class ScreenOffGuardTest {
    private class FakeSettings(var timeout: String?) : ScreenOffGuard.Settings {
        override fun get(key: String): String? = timeout
        override fun put(key: String, value: String) { timeout = value }
    }

    @Before fun fresh() = ScreenOffGuard.resetForTest()

    private val long = (24L * 60 * 60 * 1000).toString()

    @Test fun aNormalSessionRaisesTheTimeoutAndPutsTheOriginalBack() {
        val prefs = FakeSharedPreferences(); val settings = FakeSettings("30000")
        ScreenOffGuard.keepAwake(prefs, settings, "a")
        assertEquals(long, settings.timeout)
        assertTrue(ScreenOffGuard.release("a"))
        ScreenOffGuard.restore(prefs, settings)
        assertEquals("30000", settings.timeout)
        ScreenOffGuard.restore(prefs, settings) // idempotent: nothing is marked any more
        assertEquals("30000", settings.timeout)
    }

    @Test fun aFailedReadFallsBackToTheDefaultInsteadOfStrandingTheLongTimeout() {
        val prefs = FakeSharedPreferences(); val settings = FakeSettings(null)
        ScreenOffGuard.keepAwake(prefs, settings, "a")
        assertEquals(long, settings.timeout)
        ScreenOffGuard.release("a")
        ScreenOffGuard.restore(prefs, settings)
        assertEquals(ScreenOffGuard.DEFAULT_TIMEOUT_MS, settings.timeout)
    }

    @Test fun aSessionThatReplacesAnotherKeepsTheTimeoutUntilTheLastOneLetsGo() {
        val prefs = FakeSharedPreferences(); val settings = FakeSettings("45000")
        ScreenOffGuard.keepAwake(prefs, settings, "old")
        ScreenOffGuard.keepAwake(prefs, settings, "new") // the new mirror starts, then the old one ends
        assertFalse("the old session is not the last", ScreenOffGuard.release("old"))
        ScreenOffGuard.restore(prefs, settings)
        assertEquals("still raised for the live session", long, settings.timeout)
        assertTrue(ScreenOffGuard.release("new"))
        ScreenOffGuard.restore(prefs, settings)
        assertEquals("the original, not the raised value the second session saw", "45000", settings.timeout)
    }

    @Test fun recoveryRestoresAnOrphanedTimeoutButNeverFightsALiveSession() {
        val prefs = FakeSharedPreferences(); val settings = FakeSettings("30000")
        ScreenOffGuard.keepAwake(prefs, settings, "live")
        ScreenOffGuard.recoverIfOrphaned(prefs, settings)
        assertEquals("a live session is left alone", long, settings.timeout)
        ScreenOffGuard.resetForTest() // the process was killed: no holder survives, the marker does
        ScreenOffGuard.recoverIfOrphaned(prefs, settings)
        assertEquals("30000", settings.timeout)
    }
}
