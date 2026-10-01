package dev.vmd1.gossip.features.battery

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.util.Log
import dev.vmd1.gossip.protocol.Envelope
import dev.vmd1.gossip.protocol.MessageType
import dev.vmd1.gossip.transport.EnvelopeHandler
import dev.vmd1.gossip.transport.MessageRouter
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive

private const val TAG = "BatterySync"

/** A device's battery as last reported over the mesh (`battery.update`). */
data class BatteryState(val level: Int, val isCharging: Boolean)

/**
 * Implements `battery.update` (see `schema/message-types.md`): broadcasts this device's battery
 * level + charging state to the whole mesh, tracks every other device's last report for the
 * paired-devices UI, and raises a low-battery alert (via [onLowBattery]) when a peer drops to
 * [LOW_THRESHOLD] or below while not charging.
 *
 * **Reconciled**, per this repo's `CLAUDE.md` convention: sent on every local change (level or
 * charging flip), on every fresh `CONNECTED` transition, and every 60s while connected —
 * [reportInitialSyncState]/[periodicResync], driven from `SyncForegroundService` exactly like
 * `HotspotStateManager`. Receiving is last-write-wins per sender and idempotent; the low-battery
 * alert fires once per low *episode* (re-armed only after the peer charges or climbs back above
 * [REARM_LEVEL]) so a duplicate/resynced report can never re-alert.
 */
class BatterySyncManager(
    /** Only needed for the live system battery receiver/reader; `null` in unit tests. */
    private val context: Context?,
    private val deviceId: String,
    private val messageRouter: MessageRouter,
    private val send: suspend (Envelope) -> Unit,
    private val scope: CoroutineScope,
    private val readBattery: () -> BatteryState? = { context?.let(::readFromSystem) },
    private val onLowBattery: (senderId: String, level: Int) -> Unit = { _, _ -> },
    private val isEnabled: () -> Boolean = { true }
) {
    private val _states = MutableStateFlow<Map<String, BatteryState>>(emptyMap())
    val batteryBySenderId: StateFlow<Map<String, BatteryState>> = _states.asStateFlow()

    private var lastReported: BatteryState? = null
    private val alerted = mutableSetOf<String>()
    private var receiverRegistered = false

    private val changeReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, intent: Intent) { reportCurrentState() }
    }

    private val updateHandler = EnvelopeHandler { handleUpdate(it) }

    fun start() {
        messageRouter.register(MessageType.BATTERY_UPDATE, updateHandler)
        if (!receiverRegistered && context != null) {
            context.registerReceiver(changeReceiver, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            receiverRegistered = true
        }
    }

    fun stop() {
        messageRouter.unregister(updateHandler)
        if (receiverRegistered) {
            runCatching { context?.unregisterReceiver(changeReceiver) }
            receiverRegistered = false
        }
    }

    /** Sends the current reading if it differs from the last one sent. */
    fun reportCurrentState() {
        if (!isEnabled()) return
        val now = readBattery() ?: return
        if (now == lastReported) return
        lastReported = now
        sendState(now)
    }

    /** Sends the current reading unconditionally — on every fresh connection and every 60s
     *  while connected, so a missed/dropped report self-heals. */
    fun periodicResync() {
        if (!isEnabled()) return
        val now = readBattery() ?: return
        lastReported = now
        sendState(now)
    }

    fun reportInitialSyncState() = periodicResync()

    private fun sendState(state: BatteryState) {
        val envelope = Envelope(
            type = MessageType.BATTERY_UPDATE,
            senderId = deviceId,
            broadcast = true,
            payload = payload(deviceId, state)
        )
        scope.launch { runCatching { send(envelope) }.onFailure { Log.w(TAG, "Failed to send battery.update", it) } }
    }

    private fun handleUpdate(envelope: Envelope) {
        val level = envelope.payload["level"]?.jsonPrimitive?.contentOrNull?.toIntOrNull()?.coerceIn(0, 100) ?: return
        val charging = envelope.payload["isCharging"]?.jsonPrimitive?.contentOrNull?.toBooleanStrictOrNull() ?: return
        val sender = envelope.senderId
        _states.value = _states.value + (sender to BatteryState(level, charging))
        val shouldAlert = synchronized(alerted) {
            when {
                charging || level > REARM_LEVEL -> { alerted.remove(sender); false }
                level <= LOW_THRESHOLD -> alerted.add(sender)  // false if already alerted this episode
                else -> false
            }
        }
        if (shouldAlert) onLowBattery(sender, level)
    }

    companion object {
        const val LOW_THRESHOLD = 20
        const val REARM_LEVEL = 30

        fun payload(sourceDeviceId: String, state: BatteryState) = buildJsonObject {
            put("sourceDeviceId", JsonPrimitive(sourceDeviceId))
            put("level", JsonPrimitive(state.level))
            put("isCharging", JsonPrimitive(state.isCharging))
        }

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
