package dev.vmd1.gossip.features.battery

import dev.vmd1.gossip.transport.TransportManager
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class BatterySyncManagerTest {
    private val published = mutableListOf<Pair<String, JsonElement?>>()
    private val alerts = mutableListOf<Pair<String, Int>>()
    private var reading: BatteryState? = BatteryState(80, false)
    private val changes = MutableSharedFlow<TransportManager.StateChange>(extraBufferCapacity = 16)

    private fun TestScope.manager(enabled: () -> Boolean = { true }) =
        BatterySyncManager(
            context = null, scope = TestScope(UnconfinedTestDispatcher(testScheduler)),
            setState = { slot, value -> published += slot to value }, stateChanges = changes,
            readBattery = { reading }, onLowBattery = { id, l -> alerts += id to l }, isEnabled = enabled
        )

    private fun slot(from: String, level: Int, charging: Boolean) = TransportManager.StateChange(
        from, "battery.state",
        buildJsonObject { put("level", JsonPrimitive(level)); put("isCharging", JsonPrimitive(charging)) }, 1uL
    )

    @Test
    fun `publishes only when the reading changes`() = runTest {
        val m = manager()
        m.reportCurrentState(); m.reportCurrentState()
        assertEquals(1, published.size)
        assertEquals("battery.state", published.single().first)
        reading = BatteryState(79, false); m.reportCurrentState()
        assertEquals(2, published.size)
    }

    @Test
    fun `disabled feature publishes nothing and a missing battery publishes nothing`() = runTest {
        manager(enabled = { false }).reportCurrentState()
        reading = null; manager().reportCurrentState()
        assertEquals(0, published.size)
    }

    @Test
    fun `tracks the last report per sender (last write wins, idempotent)`() = runTest {
        val m = manager(); m.start()
        changes.emit(slot("a", 50, false)); changes.emit(slot("a", 50, false)); changes.emit(slot("a", 60, true))
        assertEquals(BatteryState(60, true), m.batteryBySenderId.value["a"])
        assertNull(m.batteryBySenderId.value["b"])
        changes.emit(TransportManager.StateChange("a", "battery.state", null, 2uL))
        assertNull("a revoked device's reading is dropped", m.batteryBySenderId.value["a"])
    }

    @Test
    fun `low battery alerts once per episode and re-arms after charging`() = runTest {
        val m = manager(); m.start()
        changes.emit(slot("a", 19, false)); changes.emit(slot("a", 19, false)); changes.emit(slot("a", 18, false))
        assertEquals(listOf("a" to 19), alerts)
        changes.emit(slot("a", 25, false)); changes.emit(slot("a", 15, false))   // not yet re-armed (<=30)
        assertEquals(1, alerts.size)
        changes.emit(slot("a", 40, false)); changes.emit(slot("a", 20, false))   // re-armed
        assertEquals(2, alerts.size)
        changes.emit(slot("b", 10, true))                                          // charging: no alert
        assertEquals(2, alerts.size)
    }
}
