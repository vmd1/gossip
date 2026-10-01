package dev.vmd1.gossip.features.battery

import dev.vmd1.gossip.protocol.Envelope
import dev.vmd1.gossip.protocol.MessageType
import dev.vmd1.gossip.transport.MessageRouter
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class BatterySyncManagerTest {
    private val sent = mutableListOf<Envelope>()
    private val alerts = mutableListOf<Pair<String, Int>>()
    private var reading: BatteryState? = BatteryState(80, false)

    private fun TestScope.manager(router: MessageRouter = MessageRouter(), enabled: () -> Boolean = { true }) =
        BatterySyncManager(
            context = null, deviceId = "me", messageRouter = router, send = { sent += it },
            scope = TestScope(UnconfinedTestDispatcher(testScheduler)), readBattery = { reading },
            onLowBattery = { id, l -> alerts += id to l }, isEnabled = enabled
        )

    private fun update(from: String, level: Int, charging: Boolean) = Envelope(
        type = MessageType.BATTERY_UPDATE, senderId = from, broadcast = true,
        payload = BatterySyncManager.payload(from, BatteryState(level, charging))
    )

    @Test
    fun `reports only on change, but resync always sends`() = runTest {
        val m = manager()
        m.reportCurrentState(); m.reportCurrentState()
        assertEquals(1, sent.size)
        reading = BatteryState(79, false); m.reportCurrentState()
        assertEquals(2, sent.size)
        m.periodicResync(); m.reportInitialSyncState()
        assertEquals(4, sent.size)
        assertEquals(true, sent.all { it.broadcast && it.type == MessageType.BATTERY_UPDATE })
    }

    @Test
    fun `disabled feature sends nothing and a missing battery sends nothing`() = runTest {
        manager(enabled = { false }).periodicResync()
        reading = null; manager().periodicResync()
        assertEquals(0, sent.size)
    }

    @Test
    fun `tracks the last report per sender (last write wins, idempotent)`() = runTest {
        val router = MessageRouter(); val m = manager(router); m.start()
        router.dispatch(update("a", 50, false)); router.dispatch(update("a", 50, false)); router.dispatch(update("a", 60, true))
        assertEquals(BatteryState(60, true), m.batteryBySenderId.value["a"])
        assertNull(m.batteryBySenderId.value["b"])
    }

    @Test
    fun `low battery alerts once per episode and re-arms after charging`() = runTest {
        val router = MessageRouter(); val m = manager(router); m.start()
        router.dispatch(update("a", 19, false)); router.dispatch(update("a", 19, false)); router.dispatch(update("a", 18, false))
        assertEquals(listOf("a" to 19), alerts)
        router.dispatch(update("a", 25, false)); router.dispatch(update("a", 15, false))   // not yet re-armed (<=30)
        assertEquals(1, alerts.size)
        router.dispatch(update("a", 40, false)); router.dispatch(update("a", 20, false))   // re-armed
        assertEquals(2, alerts.size)
        router.dispatch(update("b", 10, true))                                              // charging: no alert
        assertEquals(2, alerts.size)
    }
}
