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

    private val setHandler = EnvelopeHandler { envelope ->
        val payload = DndSetPayload.fromJsonObject(envelope.payload)
        applyRequestedState(payload.enabled)
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
    }

    fun stop() {
        if (receiverRegistered) {
            runCatching { context.unregisterReceiver(filterChangedReceiver) }
            receiverRegistered = false
        }
        messageRouter.unregister(setHandler)
    }

    /** Sends `dnd.update` reflecting the current interruption filter. Call once after
     *  [start] (once connected) to sync initial state, in addition to the receiver firing
     *  on subsequent changes. */
    fun reportCurrentState() {
        val enabled = interruptionFilterToEnabled(notificationManager.currentInterruptionFilter)
        val envelope = Envelope(
            type = MessageType.DND_UPDATE,
            senderId = identityKeyStore.deviceId,
            payload = DndUpdatePayload(
                sourceDeviceId = identityKeyStore.deviceId,
                enabled = enabled
            ).toJsonObject()
        )
        scope.launch {
            runCatching { transportManager.send(envelope) }
                .onFailure { Log.w(TAG, "Failed to send dnd.update: ${it.message}") }
        }
    }

    private fun applyRequestedState(enabled: Boolean) {
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
