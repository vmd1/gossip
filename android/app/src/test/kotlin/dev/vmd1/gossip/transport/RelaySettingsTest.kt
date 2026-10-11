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
    fun followsTheNewestEditAcrossTheMesh() {
        val settings = RelaySettings(FakeSharedPreferences()) { 1_000L }
        val published = mutableListOf<uniffi.gossip_ffi.RelayConfig>()
        settings.onChange = { published += it }
        assertEquals(0L, settings.changedAt)
        // A device that was never edited adopts a peer's choice, keeping the peer's timestamp.
        val theirs = uniffi.gossip_ffi.RelayConfig(true, "wss://eu.example.com", 500L)
        assertTrue(settings.adopt(theirs))
        assertTrue(settings.enabled.value)
        assertEquals("wss://eu.example.com", settings.customUrl.value)
        assertEquals(500L, settings.changedAt)
        // Applying it again, or an older choice, changes nothing.
        assertFalse(settings.adopt(theirs))
        assertFalse(settings.adopt(uniffi.gossip_ffi.RelayConfig(false, null, 400L)))
        assertTrue(settings.enabled.value)
        // A local edit is stamped and published, and beats what was adopted.
        settings.setEnabled(false)
        assertEquals(1_000L, settings.changedAt)
        assertEquals(false, published.last().enabled)
        assertFalse(settings.adopt(theirs))
        // Setting the same value is not an edit.
        val before = published.size
        settings.setEnabled(false)
        assertEquals(before, published.size)
    }

    @Test
    fun offByDefaultAndTheBuiltInDefaultNeedsNoSetup() {
        val settings = RelaySettings(FakeSharedPreferences())
        assertFalse(settings.enabled.value)
        assertEquals(RelaySettings.Configuration(false, null), settings.configuration())
        settings.setEnabled(true)
        assertEquals(RelaySettings.Configuration(true, "wss://gossip.vmd1.dev"), settings.configuration())
        assertEquals(RelaySettings.Configuration(true, "wss://eu.vmd1.dev"), settings.configuration("wss://eu.vmd1.dev", true))
        assertEquals("held back while the first directory answer is pending", RelaySettings.Configuration(false, null), settings.configuration(awaitingDirectory = true))
        settings.setCustomUrl("wss://my.relay.test")
        assertEquals("custom wins and never waits", RelaySettings.Configuration(true, "wss://my.relay.test"), settings.configuration("wss://eu.vmd1.dev", true, awaitingDirectory = true))
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
        assertEquals(RelaySettings.Configuration(false, null), settings.configuration("wss://eu.vmd1.dev", true))
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
        assertEquals("The custom relay address is not valid", line(origin = false))
        assertEquals("Connected to the relay", line())
        assertEquals("Connecting…", line(status = "connecting"))
        assertEquals("Not connected, retrying", line(status = "disconnected"))
        assertEquals("The relay needs a newer version of Gossip", line(status = "disconnected", error = "upgrade_required"))
        assertTrue(line(status = "no_topic").startsWith("Waiting for a paired device"))
        assertTrue(line(status = "disabled", idle = true).startsWith("On, waiting"))
    }
}
