package dev.vmd1.gossip.transport

import dev.vmd1.gossip.crypto.FakeSharedPreferences
import dev.vmd1.gossip.ui.RelayStatusText
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RelaySettingsTest {
    @Test
    fun offByDefaultAndTheShippedPlaceholderNeverYieldsAnOrigin() {
        val settings = RelaySettings(FakeSharedPreferences())
        assertFalse(settings.enabled.value)
        settings.setEnabled(true)
        assertEquals("on, but no host configured: stays off", RelaySettings.Configuration(false, null), settings.configuration())
    }

    @Test
    fun aValidCustomAddressEnablesItAndPersists() {
        val prefs = FakeSharedPreferences()
        RelaySettings(prefs).apply { setEnabled(true); setCustomUrl("wss://my.relay.test") }
        val reloaded = RelaySettings(prefs)
        assertTrue(reloaded.enabled.value)
        assertEquals(RelaySettings.Configuration(true, "wss://my.relay.test"), reloaded.configuration())
        reloaded.setEnabled(false)
        assertEquals(RelaySettings.Configuration(false, null), reloaded.configuration())
    }

    @Test
    fun anInvalidCustomAddressNeverReachesTheEngine() {
        val settings = RelaySettings(FakeSharedPreferences()).apply { setEnabled(true); setCustomUrl("ws://insecure.test") }
        assertEquals(RelaySettings.Configuration(false, null), settings.configuration())
    }

    @Test
    fun theTopicRoundTripsAndRejectsDamagedData() {
        val prefs = FakeSharedPreferences()
        val store = RelayTopicStore(prefs)
        assertNull(store.load())
        val secret = ByteArray(32) { it.toByte() }
        assertTrue(store.save(secret, 7))
        val loaded = RelayTopicStore(prefs).load()!!
        assertArrayEquals(secret, loaded.secret)
        assertEquals(7L, loaded.epoch)
        prefs.edit().putString("topic_secret", "AAAA").commit()
        assertNull("a secret of the wrong length is ignored", RelayTopicStore(prefs).load())
    }

    @Test
    fun statusLinesFollowTheEngineState() {
        fun line(enabled: Boolean = true, origin: Boolean = true, status: String = "joined", idle: Boolean = false, error: String? = null) =
            RelayStatusText.line(enabled, origin, status, idle, error)
        assertEquals("Off", line(enabled = false))
        assertEquals("No relay host configured", line(origin = false))
        assertEquals("Connected to the relay", line())
        assertEquals("Connecting…", line(status = "connecting"))
        assertEquals("Not connected, retrying", line(status = "disconnected"))
        assertEquals("The relay needs a newer version of Gossip", line(status = "disconnected", error = "upgrade_required"))
        assertTrue(line(status = "no_topic").startsWith("Waiting for a paired device"))
        assertTrue(line(status = "disabled", idle = true).startsWith("On, waiting"))
    }
}
