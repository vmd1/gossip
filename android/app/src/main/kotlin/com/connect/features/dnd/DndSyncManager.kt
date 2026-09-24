package com.connect.features.dnd

import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.provider.Settings
import android.util.Log
import com.connect.crypto.IdentityKeyStore
import com.connect.protocol.Envelope
import com.connect.protocol.MessageType
import com.connect.transport.EnvelopeHandler
import com.connect.transport.MessageRouter
import com.connect.transport.TransportManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

private const val TAG = "DndSyncManager"

/**
 * Bridges Android's Do Not Disturb (Focus) state with the paired Mac.
 *
 * Reporting (Android -> Mac): observes `NotificationManager`'s interruption filter via a
 * `BroadcastReceiver` for `ACTION_INTERRUPTION_FILTER_CHANGED` and sends `dnd.update`.
 *
 * Control (Mac -> Android): registers a [MessageRouter] handler for `dnd.set` and calls
 * `NotificationManager.setInterruptionFilter(...)` in response.
 *
 * Auto-reconciliation: a `dnd.update` that disagrees with [expectedState] is also applied
 * locally (same as `dnd.set`), so toggling either device's Focus/DND mirrors onto the
 * other. This creates a feedback-loop risk symmetric to the Mac side's Shortcuts
 * automation echo: applying a peer-requested state fires our own
 * `ACTION_INTERRUPTION_FILTER_CHANGED` receiver for the *same* change we just made.
 * [expectedState] dedupes that (same convention as `clipboard.update`, see
 * `schema/message-types.md`), and [reconcileCooldownMs] is a belt-and-suspenders guard
 * against that broadcast's delivery timing racing the in-memory state update.
 *
 * Requires `ACCESS_NOTIFICATION_POLICY` ("Do Not Disturb access" / notification policy
 * access) — a special-access grant the user must enable manually in Settings, there is
 * no runtime permission dialog for it. See [requestPolicyAccessIntent] for the
 * onboarding deep link, wired up from the UI (analogous to the "Pair New Device" flow).
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

    /** The DND state this device is currently believed to be in — either the last state
     *  we reported ourselves, or the last peer-requested state we applied. Used to dedupe
     *  echoes of our own changes (see class doc). */
    private var expectedState: Boolean? = null

    /** When we last called [applyRequestedState] to apply a peer-requested change. */
    private var lastAppliedAt: Long? = null
    private val reconcileCooldownMs = 3000L

    private val setHandler = EnvelopeHandler { envelope ->
        val payload = DndSetPayload.fromJsonObject(envelope.payload)
        applyRequestedState(payload.enabled)
    }

    /** A `dnd.update` report from the peer that disagrees with [expectedState] is treated
     *  the same as an explicit `dnd.set` request — see class doc for why this is safe
     *  against feedback loops. An `isInitialSync` report (sent once per fresh connection,
     *  see [reportInitialSyncState]) instead goes through [handleInitialSync]'s OR-merge,
     *  since two devices that were already mismatched *before* connecting need a real
     *  merge decision, not a blind mirror — see that function's doc for why. */
    private val updateHandler = EnvelopeHandler { envelope ->
        val payload = DndUpdatePayload.fromJsonObject(envelope.payload)
        if (payload.isInitialSync) {
            handleInitialSync(remoteEnabled = payload.enabled)
        } else if (payload.enabled != expectedState) {
            applyRequestedState(payload.enabled)
        }
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

    /** Starts observing local DND changes and handling incoming `dnd.set` requests. Safe
     *  to call even before notification policy access is granted; reporting/handling
     *  simply no-op (or log) until it is. */
    fun start() {
        if (!receiverRegistered) {
            context.registerReceiver(
                filterChangedReceiver,
                IntentFilter(NotificationManager.ACTION_INTERRUPTION_FILTER_CHANGED)
            )
            receiverRegistered = true
        }
        messageRouter.register(MessageType.DND_SET, setHandler)
        messageRouter.register(MessageType.DND_UPDATE, updateHandler)
    }

    fun stop() {
        if (receiverRegistered) {
            runCatching { context.unregisterReceiver(filterChangedReceiver) }
            receiverRegistered = false
        }
        messageRouter.unregister(setHandler)
        messageRouter.unregister(updateHandler)
    }

    /** Sends `dnd.update` reflecting the current interruption filter. Called whenever a
     *  local DND change is observed (see [filterChangedReceiver]). */
    fun reportCurrentState() {
        val enabled = interruptionFilterToEnabled(notificationManager.currentInterruptionFilter)

        val lastAppliedAt = lastAppliedAt
        if (lastAppliedAt != null && System.currentTimeMillis() - lastAppliedAt < reconcileCooldownMs) {
            return
        }
        if (enabled == expectedState) return
        expectedState = enabled
        send(enabled = enabled, isInitialSync = false)
    }

    /** Sends this device's real current DND state as an `isInitialSync` report — call once
     *  per fresh connection (`SyncForegroundService` does this on every transition to
     *  `CONNECTED`). Unlike [reportCurrentState], this always sends regardless of
     *  [expectedState], since the whole point is telling a peer we may never have told
     *  before (or whose belief about us predates this connection).
     *
     *  Two devices can each have been independently toggled while apart, so a fresh
     *  connection may find them genuinely disagreeing — not because either device did
     *  anything wrong, just because nothing synced them yet. Blindly mirroring whichever
     *  report arrives would let concurrent reports from both sides *swap* their states
     *  (each mirrors the other's stale value). [handleInitialSync] instead ORs the peer's
     *  reported state with this device's own real state: DND ends up on if *either* side
     *  had it on, which both sides converge to independently and order-independently. */
    fun reportInitialSyncState() {
        val enabled = interruptionFilterToEnabled(notificationManager.currentInterruptionFilter)
        expectedState = enabled
        send(enabled = enabled, isInitialSync = true)
    }

    /** OR-merges an `isInitialSync` peer report against this device's own real current
     *  state (see [reportInitialSyncState]'s doc for why this must be a merge, not a
     *  mirror). Only actually changes anything if the merge disagrees with local truth. */
    private fun handleInitialSync(remoteEnabled: Boolean) {
        val localEnabled = interruptionFilterToEnabled(notificationManager.currentInterruptionFilter)
        val target = localEnabled || remoteEnabled
        if (target != localEnabled) {
            applyRequestedState(target)
        } else {
            expectedState = target
        }
    }

    private fun send(enabled: Boolean, isInitialSync: Boolean) {
        val envelope = Envelope(
            type = MessageType.DND_UPDATE,
            senderId = identityKeyStore.deviceId,
            // Unlike Mac's DNDSyncManager, this never set `broadcast`/`recipientId` —
            // harmless under the old single-peer send() (which ignored both and just
            // used whatever the one connection was), but silently dropped under the
            // mesh-aware send() (nothing to resolve a target from). Must reach every
            // trusted device in the mesh, not just one, so it's a broadcast.
            broadcast = true,
            payload = DndUpdatePayload(
                sourceDeviceId = identityKeyStore.deviceId,
                enabled = enabled,
                isInitialSync = isInitialSync
            ).toJsonObject()
        )
        scope.launch {
            runCatching { transportManager.send(envelope) }
                .onFailure { Log.w(TAG, "Failed to send dnd.update", it) }
        }
    }

    private fun applyRequestedState(enabled: Boolean) {
        expectedState = enabled
        lastAppliedAt = System.currentTimeMillis()

        if (!hasNotificationPolicyAccess()) {
            Log.w(TAG, "Received dnd.set but notification policy access is not granted; ignoring")
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
         * Maps `NotificationManager`'s interruption filter to the simple on/off DND state
         * carried on the wire.
         *
         * This is a deliberate simplification: Android distinguishes several "DND on"
         * filters (`PRIORITY`, `NONE`, `ALARMS`) with different allow-lists, but Connect's
         * `dnd.update`/`dnd.set` messages only carry a single boolean. `INTERRUPTION_FILTER_ALL`
         * is the only "everything gets through" state, so it alone maps to `enabled=false`;
         * every other filter (`PRIORITY`, `NONE`, `ALARMS`, or any unrecognized future value)
         * maps to `enabled=true`. Note this makes the mapping lossy in one direction: setting
         * `enabled=true` (see [applyRequestedState]) always requests
         * `INTERRUPTION_FILTER_PRIORITY` specifically, regardless of which "on" filter was
         * last observed.
         */
        fun interruptionFilterToEnabled(filter: Int): Boolean =
            filter != NotificationManager.INTERRUPTION_FILTER_ALL
    }
}
