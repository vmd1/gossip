package dev.vmd1.gossip.features.settings

import dev.vmd1.gossip.crypto.FakeSharedPreferences
import dev.vmd1.gossip.protocol.Envelope
import dev.vmd1.gossip.transport.EnvelopeHandler
import dev.vmd1.gossip.transport.MessageRouter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FeatureSettingsTest {
    @Test
    fun `every feature is on by default`() {
        val settings = FeatureSettings(FakeSharedPreferences())
        for (f in Feature.values()) assertTrue(f.name, settings.isEnabled(f))
        assertTrue(settings.disabled.value.isEmpty())
    }

    @Test
    fun `a toggle is independent and persists`() {
        val prefs = FakeSharedPreferences()
        val settings = FeatureSettings(prefs)
        settings.setEnabled(Feature.CLIPBOARD, false)
        assertFalse(settings.isEnabled(Feature.CLIPBOARD))
        assertTrue(settings.isEnabled(Feature.DND))
        assertEquals(setOf(Feature.CLIPBOARD), settings.disabled.value)

        val reloaded = FeatureSettings(prefs)
        assertFalse(reloaded.isEnabled(Feature.CLIPBOARD))
        assertTrue(reloaded.isEnabled(Feature.DND))

        reloaded.setEnabled(Feature.CLIPBOARD, true)
        assertTrue(FeatureSettings(prefs).isEnabled(Feature.CLIPBOARD))
    }

    @Test
    fun `message types map to their feature`() {
        assertEquals(Feature.CLIPBOARD, FeatureSettings.featureForMessageType("clipboard.update"))
        assertEquals(Feature.DND, FeatureSettings.featureForMessageType("dnd.update"))
        assertEquals(Feature.NOTIFICATIONS, FeatureSettings.featureForMessageType("notification.reply"))
        assertEquals(Feature.MEDIA, FeatureSettings.featureForMessageType("media.command"))
        assertEquals(Feature.LOCK_ON_LEAVE, FeatureSettings.featureForMessageType("lock_on_leave.config"))
        assertEquals(Feature.HOTSPOT, FeatureSettings.featureForMessageType("hotspot.state_update"))
        assertEquals(Feature.FIND_DEVICE, FeatureSettings.featureForMessageType("device.ring"))
        assertEquals(Feature.BATTERY, FeatureSettings.featureForMessageType("battery.update"))
        for (unowned in listOf("handshake.hello", "presence.heartbeat", "trust.roster_update", "screen.start", "screen.ready")) {
            assertNull(unowned, FeatureSettings.featureForMessageType(unowned))
        }
    }

    @Test
    fun `router drops a disabled feature and delivers the rest`() {
        val settings = FeatureSettings(FakeSharedPreferences())
        val router = MessageRouter(isMessageAllowed = settings::isMessageAllowed)
        val received = mutableListOf<String>()
        router.register("clipboard.", EnvelopeHandler { received += it.type })
        router.register("dnd.", EnvelopeHandler { received += it.type })

        settings.setEnabled(Feature.CLIPBOARD, false)
        router.dispatch(Envelope(type = "clipboard.update", senderId = "x"))
        router.dispatch(Envelope(type = "dnd.update", senderId = "x"))
        assertEquals(listOf("dnd.update"), received)

        settings.setEnabled(Feature.CLIPBOARD, true)
        router.dispatch(Envelope(type = "clipboard.update", senderId = "x"))
        assertEquals(listOf("dnd.update", "clipboard.update"), received)
    }
}
