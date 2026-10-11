package dev.vmd1.gossip.features.dnd

import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.provider.Settings
import dev.vmd1.gossip.util.Log
import dev.vmd1.gossip.crypto.IdentityKeyStore
import dev.vmd1.gossip.protocol.MessageType
import dev.vmd1.gossip.transport.EnvelopeHandler
import dev.vmd1.gossip.transport.MessageRouter
import dev.vmd1.gossip.transport.TransportManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import uniffi.gossip_ffi.Dnd as CoreDnd
import uniffi.gossip_ffi.DndEffect
import uniffi.gossip_ffi.dndSlot

private const val TAG = "DndSyncManager"

/**
 * Bridges Android's Do Not Disturb (Focus) state with the other devices in the mesh.
 *
 * Reporting: observes `NotificationManager`'s interruption filter via a `BroadcastReceiver` for
 * `ACTION_INTERRUPTION_FILTER_CHANGED` and publishes it as the `dnd.state` state slot (see `docs/plans/state-sync.md`), so
 * the core keeps every other device's copy correct, including for devices that connect later. Nothing resends it.
 *
 * Control: registers a [MessageRouter] handler for `dnd.set` and calls `NotificationManager.setInterruptionFilter(...)` in
 * response; a peer's `dnd.state` that disagrees with what this device believes is applied the same way, so toggling either
 * device's Focus/DND mirrors onto the other.
 *
 * The decisions (echo suppression, the cooldown that swallows the broadcast caused by applying a peer's state, and the
 * OR-merge of the first state seen from a device) are the core's `Dnd` (`desktop/core/src/features/dnd.rs`), shared with
 * every platform; this class only talks to the OS.
 *
 * Requires `ACCESS_NOTIFICATION_POLICY` ("Do Not Disturb access" / notification policy access) — a special-access grant the
 * user must enable manually in Settings, there is no runtime permission dialog for it. See [requestPolicyAccessIntent].
 */
class DndSyncManager(
    private val context: Context,
    private val identityKeyStore: IdentityKeyStore,
    private val transportManager: TransportManager,
    private val messageRouter: MessageRouter,
    private val scope: CoroutineScope
) {
    private val notificationManager: NotificationManager =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private var receiverRegistered = false
    private val logic = CoreDnd(null)
    private val lock = Any()
    private var stateJob: kotlinx.coroutines.Job? = null

    private val setHandler = EnvelopeHandler { envelope ->
        val payload = DndSetPayload.fromJsonObject(envelope.payload)
        synchronized(lock) { carryOut(logic.onSet("""{"enabled":${payload.enabled}}""", System.currentTimeMillis())) }
    }

    private val filterChangedReceiver = object : BroadcastReceiver() {
        override fun onReceive(receiverContext: Context, intent: Intent) {
            reportCurrentState()
        }
    }

    /** True once the user has granted notification policy access via Settings. */
    fun hasNotificationPolicyAccess(): Boolean = notificationManager.isNotificationPolicyAccessGranted

    /** Deep link for onboarding: opens the system settings screen to grant DND access,
     *  since this is a special-access grant with no runtime permission dialog. */
    fun requestPolicyAccessIntent(): Intent = Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS)

    /** Starts observing local DND changes and handling incoming requests and peers' states. Safe to call even before
     *  notification policy access is granted; applying simply no-ops (with a log) until it is. */
    fun start() {
        if (!receiverRegistered) {
            context.registerReceiver(
                filterChangedReceiver,
                IntentFilter(NotificationManager.ACTION_INTERRUPTION_FILTER_CHANGED)
            )
            receiverRegistered = true
        }
        messageRouter.register(MessageType.DND_SET, setHandler)
        stateJob?.cancel()
        stateJob = scope.launch {
            transportManager.stateChanges.collect { change ->
                if (change.slot == dndSlot()) handlePeerState(change.deviceId, change.value?.toString())
            }
        }
        // Publish the real current state; the core sends it to every device that connects later.
        reportCurrentState()
    }

    fun stop() {
        if (receiverRegistered) {
            runCatching { context.unregisterReceiver(filterChangedReceiver) }
            receiverRegistered = false
        }
        messageRouter.unregister(setHandler)
        stateJob?.cancel()
        stateJob = null
    }

    /** Reports the current interruption filter. Called whenever a local DND change is observed (see
     *  [filterChangedReceiver]) and once at start; the core ignores it when it is the state already believed. */
    fun reportCurrentState() {
        val enabled = interruptionFilterToEnabled(notificationManager.currentInterruptionFilter)
        synchronized(lock) { carryOut(logic.localChanged(enabled, System.currentTimeMillis())) }
    }

    /** A peer's `dnd.state` slot changed (`null`: cleared, or the device was revoked). The first state seen from a device is
     *  OR-merged with this device's own; later changes are mirrored. */
    private fun handlePeerState(deviceId: String, valueJson: String?) {
        synchronized(lock) {
            if (valueJson == null) {
                logic.forgetPeer(deviceId)
                return
            }
            runCatching { carryOut(logic.onPeerState(deviceId, valueJson, System.currentTimeMillis())) }
                .onFailure { Log.w(TAG, "Bad dnd.state from $deviceId", it) }
        }
    }

    private fun carryOut(effects: List<DndEffect>) {
        for (effect in effects) {
            when (effect) {
                is DndEffect.SetState -> transportManager.setState(effect.slot, kotlinx.serialization.json.Json.parseToJsonElement(effect.valueJson))
                is DndEffect.ApplyLocal -> applyRequestedState(effect.enabled)
                is DndEffect.Persist -> Unit // the OS can be read back, so nothing is persisted here
            }
        }
    }

    private fun applyRequestedState(enabled: Boolean) {
        if (!hasNotificationPolicyAccess()) {
            Log.w(TAG, "Asked to change Do Not Disturb but notification policy access is not granted; ignoring")
            return
        }
        val filter = if (enabled) {
            NotificationManager.INTERRUPTION_FILTER_PRIORITY
        } else {
            NotificationManager.INTERRUPTION_FILTER_ALL
        }
        runCatching { notificationManager.setInterruptionFilter(filter) }
            .onFailure { Log.w(TAG, "Failed to set interruption filter: ${it.message}") }
    }

    companion object {
        /**
         * Maps `NotificationManager`'s interruption filter to the simple on/off DND state carried on the wire.
         *
         * This is a deliberate simplification: Android distinguishes several "DND on" filters (`PRIORITY`, `NONE`, `ALARMS`)
         * with different allow-lists, but the `dnd.state` slot and `dnd.set` only carry a single boolean.
         * `INTERRUPTION_FILTER_ALL` is the only "everything gets through" state, so it alone maps to `enabled=false`; every
         * other filter maps to `enabled=true`. Setting `enabled=true` always requests `INTERRUPTION_FILTER_PRIORITY`.
         */
        fun interruptionFilterToEnabled(filter: Int): Boolean =
            filter != NotificationManager.INTERRUPTION_FILTER_ALL
    }
}
