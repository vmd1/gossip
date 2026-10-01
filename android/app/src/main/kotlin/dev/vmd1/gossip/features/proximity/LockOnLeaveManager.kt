package dev.vmd1.gossip.features.proximity

import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.util.Log
import dev.vmd1.gossip.crypto.IdentityKeyStore
import dev.vmd1.gossip.crypto.TrustedDevicesStore
import dev.vmd1.gossip.protocol.DeviceType
import dev.vmd1.gossip.protocol.Envelope
import dev.vmd1.gossip.protocol.MessageType
import dev.vmd1.gossip.transport.EnvelopeHandler
import dev.vmd1.gossip.transport.MessageRouter
import dev.vmd1.gossip.transport.TransportManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Tablet-side counterpart to Mac's `LockOnLeaveManager.swift` — implements the receiving
 * and acting half of `lock_on_leave.config` (see `schema/message-types.md`): a phone tells
 * this device (Mac or, here, a tablet) whether to lock itself when that phone leaves BLE
 * range. No message is needed for the trigger itself, only the config: this device is
 * always the BLE central for phones (`docs/ble-proximity-protocol.md`), so it already
 * knows directly, via [BLEProximityMonitor], the instant a specific trusted phone leaves
 * confirmed range.
 *
 * Fires **once per range-loss transition**, not on every tick while a device stays out of
 * range, and enforces a cooldown per device on top of that — mirrors the Mac
 * implementation exactly (including the reasoning: a device flapping in and out right at
 * the RSSI threshold must not repeatedly re-lock a screen the user has since manually
 * unlocked).
 *
 * On a **phone**, this is also the sending half of `lock_on_leave.config`: besides the
 * one-shot send `MainActivity`'s toggle already does, this reconciles the same way
 * `dnd.update`'s `isInitialSync` does — resending each trusted non-phone target's actual
 * `lockOnLeaveEnabled` intent the moment a fresh connection to it comes up, plus a 60s
 * periodic backstop while connected. Without this, a toggle sent while transiently
 * disconnected (or dropped by any other race) leaves the two sides silently and
 * permanently mismatched — the exact failure mode that motivated `dnd.update`'s own
 * resync loop, and confirmed to actually happen here too (a toggle sent before the
 * Android↔Android mesh had any discovery-driven reconnect path was silently swallowed by
 * `runCatching`, leaving Lock-on-Leave configured in the UI but never actually armed on
 * the receiving tablet). No-op on a non-phone build (a tablet/Mac only ever receives this
 * message, never originates it — see `schema/message-types.md`).
 */
class LockOnLeaveManager(
    private val context: Context,
    private val trustedDevicesStore: TrustedDevicesStore,
    private val bleProximityMonitor: BLEProximityMonitor,
    private val messageRouter: MessageRouter,
    private val transportManager: TransportManager,
    private val identityKeyStore: IdentityKeyStore,
    private val localDeviceType: DeviceType,
    private val scope: CoroutineScope,
    /** Local BLE trigger (not a message), so the transport-level feature gate can't cover it. */
    private val isEnabled: () -> Boolean = { true }
) {
    private var previousNearbyDeviceIds: Set<String> = emptySet()
    private var previousConnectedDeviceIds: Set<String> = emptySet()
    private val lastFiredAtMs = HashMap<String, Long>()

    private val configHandler = EnvelopeHandler { envelope ->
        val enabled = envelope.payload["enabled"]?.jsonPrimitive?.booleanOrNull ?: return@EnvelopeHandler
        trustedDevicesStore.setLockOnLeaveEnabled(envelope.senderId, enabled)
    }

    fun start() {
        messageRouter.register(MessageType.LOCK_ON_LEAVE_CONFIG, configHandler)
        bleProximityMonitor.nearbyDeviceIds
            .onEach { handleNearbyDeviceIdsChanged(it) }
            .launchIn(scope)

        if (localDeviceType == DeviceType.ANDROID_PHONE) {
            transportManager.connectedDeviceIds
                .onEach { handleConnectedDeviceIdsChanged(it) }
                .launchIn(scope)
            scope.launch { runPeriodicResync() }
        }
    }

    fun stop() {
        messageRouter.unregister(configHandler)
    }

    private fun handleConnectedDeviceIdsChanged(newValue: Set<String>) {
        val newlyConnected = newValue - previousConnectedDeviceIds
        previousConnectedDeviceIds = newValue
        for (deviceId in newlyConnected) {
            resyncConfig(deviceId)
        }
    }

    private suspend fun runPeriodicResync() {
        while (true) {
            delay(RESYNC_INTERVAL_MS)
            for (deviceId in transportManager.connectedDeviceIds.value) {
                resyncConfig(deviceId)
            }
        }
    }

    /** Resends this device's real, currently-stored `lockOnLeaveEnabled` intent for
     *  [deviceId] — whether `true` or `false` — so a disconnected/dropped toggle in either
     *  direction self-heals, mirroring `dnd.update`'s OR-merge motivation (though this is a
     *  plain mirror, not a merge: unlike DND, only the phone ever originates this value, so
     *  there's no concurrent-edit case to reconcile between two sources of truth). */
    private fun resyncConfig(deviceId: String) {
        val target = trustedDevicesStore.getDevice(deviceId) ?: return
        if (target.deviceType == DeviceType.ANDROID_PHONE) return
        val envelope = Envelope(
            type = MessageType.LOCK_ON_LEAVE_CONFIG,
            senderId = identityKeyStore.deviceId,
            recipientId = deviceId,
            payload = buildJsonObject { put("enabled", JsonPrimitive(target.lockOnLeaveEnabled)) }
        )
        scope.launch { runCatching { transportManager.send(envelope) } }
    }

    private fun handleNearbyDeviceIdsChanged(newValue: Set<String>) {
        val justLeft = previousNearbyDeviceIds - newValue
        previousNearbyDeviceIds = newValue
        if (!isEnabled()) return

        for (deviceId in justLeft) {
            val device = trustedDevicesStore.getDevice(deviceId)
            if (device?.lockOnLeaveEnabled != true) continue
            val last = lastFiredAtMs[deviceId]
            if (last != null && System.currentTimeMillis() - last < COOLDOWN_MS) continue
            lastFiredAtMs[deviceId] = System.currentTimeMillis()
            lockScreen()
        }
    }

    /** Requires this app to already be an active device admin (see
     *  `res/xml/device_admin.xml` and the one-time `ACTION_ADD_DEVICE_ADMIN` onboarding
     *  flow in `ui/MainActivity.kt`) — `lockNow()` throws [SecurityException] otherwise,
     *  caught here rather than crashing the BLE observation loop. */
    private fun lockScreen() {
        val dpm = context.getSystemService(DevicePolicyManager::class.java)
        val admin = ComponentName(context, ConnectDeviceAdminReceiver::class.java)
        if (dpm == null || !dpm.isAdminActive(admin)) {
            Log.w(TAG, "Cannot lock: not an active device admin")
            return
        }
        runCatching { dpm.lockNow() }
            .onFailure { Log.w(TAG, "lockNow() failed", it) }
    }

    companion object {
        private const val TAG = "LockOnLeaveManager"
        private const val COOLDOWN_MS = 30_000L
        private const val RESYNC_INTERVAL_MS = 60_000L

        fun adminComponentName(context: Context): ComponentName =
            ComponentName(context, ConnectDeviceAdminReceiver::class.java)
    }
}
