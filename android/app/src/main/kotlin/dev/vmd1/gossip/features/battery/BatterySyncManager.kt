package dev.vmd1.gossip.features.battery

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import dev.vmd1.gossip.transport.TransportManager
import dev.vmd1.gossip.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import uniffi.gossip_ffi.Battery as CoreBattery
import uniffi.gossip_ffi.BatteryEffect
import uniffi.gossip_ffi.batteryLowThreshold
import uniffi.gossip_ffi.batteryRearmLevel
import uniffi.gossip_ffi.batterySlot
import uniffi.gossip_ffi.BatteryState as CoreBatteryState

private const val TAG = "BatterySync"

/** A device's battery as last reported over the mesh (the `battery.state` slot). */
data class BatteryState(val level: Int, val isCharging: Boolean)

/**
 * Battery sync: publishes this device's battery level + charging state as the `battery.state` state slot (see
 * `docs/plans/state-sync.md`), tracks every other device's last report for the paired-devices UI, and raises a low-battery
 * alert (via [onLowBattery]) when a peer drops to [LOW_THRESHOLD] or below while not charging.
 *
 * The decisions (change detection, last-write-wins per sender, the once-per-episode alert) are the core's `Battery`
 * (`desktop/core/src/features/battery.rs`), shared with every platform; reconciliation is the core's state sync, so nothing
 * here resends on connect or on a timer. This class only reads the battery and shows the result.
 */
class BatterySyncManager(
    /** Only needed for the live system battery receiver/reader; `null` in unit tests. */
    private val context: Context?,
    private val scope: CoroutineScope,
    /** Publishes (or clears, with `null`) one of this device's state slots: [TransportManager.setState]. */
    private val setState: (slot: String, value: JsonElement?) -> Unit,
    /** Other devices' slot changes: [TransportManager.stateChanges]. */
    private val stateChanges: Flow<TransportManager.StateChange>,
    private val readBattery: () -> BatteryState? = { context?.let(::readFromSystem) },
    private val onLowBattery: (senderId: String, level: Int) -> Unit = { _, _ -> },
    private val isEnabled: () -> Boolean = { true }
) {
    private val _states = MutableStateFlow<Map<String, BatteryState>>(emptyMap())
    val batteryBySenderId: StateFlow<Map<String, BatteryState>> = _states.asStateFlow()

    private val logic = CoreBattery()
    private var receiverRegistered = false
    private var collecting: kotlinx.coroutines.Job? = null

    private val changeReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, intent: Intent) { reportCurrentState() }
    }

    fun start() {
        collecting?.cancel()
        collecting = scope.launch {
            stateChanges.collect { change -> if (change.slot == batterySlot()) handleSlot(change.deviceId, change.value) }
        }
        if (!receiverRegistered && context != null) {
            context.registerReceiver(changeReceiver, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            receiverRegistered = true
        }
        reportCurrentState()
    }

    fun stop() {
        collecting?.cancel()
        collecting = null
        if (receiverRegistered) {
            runCatching { context?.unregisterReceiver(changeReceiver) }
            receiverRegistered = false
        }
    }

    /** Publishes the current reading; the core ignores it when it is the one already published. */
    fun reportCurrentState() {
        if (!isEnabled()) return
        val reading = readBattery()?.let { CoreBatteryState(it.level.coerceIn(0, 100).toUByte(), it.isCharging) }
        val effect = logic.report(reading)
        if (effect is BatteryEffect.SetState) setState(effect.slot, Json.parseToJsonElement(effect.valueJson))
    }

    /** A peer's `battery.state` slot changed (`null`: cleared, or the device was revoked). */
    fun handleSlot(sender: String, value: JsonElement?) {
        if (value == null) {
            logic.forget(sender)
            _states.value = _states.value - sender
            return
        }
        val effects = runCatching { logic.onUpdate(sender, value.toString()) }.getOrElse {
            Log.w(TAG, "Bad battery.state from $sender", it)
            return
        }
        for (effect in effects) {
            when (effect) {
                is BatteryEffect.Updated -> logic.stateOf(effect.sender)?.let {
                    _states.value = _states.value + (effect.sender to BatteryState(it.level.toInt(), it.isCharging))
                }
                is BatteryEffect.LowBattery -> onLowBattery(effect.sender, effect.level.toInt())
                is BatteryEffect.SetState -> Unit
            }
        }
    }

    companion object {
        val LOW_THRESHOLD: Int get() = batteryLowThreshold().toInt()
        val REARM_LEVEL: Int get() = batteryRearmLevel().toInt()

        fun readFromSystem(context: Context): BatteryState? {
            val i = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)) ?: return null
            val level = i.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
            val scale = i.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
            if (level < 0 || scale <= 0) return null
            val status = i.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
            val charging = status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL
            return BatteryState(level * 100 / scale, charging)
        }
    }
}
