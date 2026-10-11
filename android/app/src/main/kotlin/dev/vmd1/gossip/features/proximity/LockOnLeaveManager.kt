package dev.vmd1.gossip.features.proximity

import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import dev.vmd1.gossip.util.Log
import dev.vmd1.gossip.crypto.IdentityKeyStore
import dev.vmd1.gossip.crypto.TrustedDevicesStore
import dev.vmd1.gossip.protocol.DeviceType
import dev.vmd1.gossip.transport.TransportManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import uniffi.gossip_ffi.LockOnLeave as CoreLockOnLeave
import uniffi.gossip_ffi.lockOnLeaveConfigPayload
import uniffi.gossip_ffi.lockOnLeaveCooldownMs
import uniffi.gossip_ffi.lockOnLeaveIsArmedFor
import uniffi.gossip_ffi.lockOnLeaveSlot

/**
 * Tablet-side counterpart to Mac's `LockOnLeaveManager.swift` — implements the receiving and acting half of the
 * `lock_on_leave.config` state slot (see `schema/message-types.md`): a phone publishes which computers it arms, and a Mac or
 * tablet that is armed locks itself when that phone leaves BLE range. No message is needed for the trigger itself: this
 * device is always the BLE central for phones (`docs/ble-proximity-protocol.md`), so it already knows directly, via
 * [BLEProximityMonitor], the instant a specific trusted phone leaves confirmed range.
 *
 * Fires **once per range-loss transition**, not on every tick while a device stays out of range, and enforces a cooldown per
 * device on top of that, so a device flapping at the RSSI threshold cannot re-lock a screen the user has since manually
 * unlocked. Both rules are the core's `LockOnLeave` (`desktop/core/src/features/lock_on_leave.rs`), shared with the Mac.
 *
 * On a **phone**, this is also the sending half: [publishArmed] sets the slot to the trusted non-phone devices whose
 * `lockOnLeaveEnabled` intent is on. The core's state sync sends the slot to every device that connects later and repairs it
 * periodically, so a toggle made while disconnected, or dropped by a race, heals itself with no resync loop here. No-op on a
 * non-phone build (a tablet/Mac only ever receives it).
 */
class LockOnLeaveManager(
    private val context: Context,
    private val trustedDevicesStore: TrustedDevicesStore,
    private val bleProximityMonitor: BLEProximityMonitor,
    private val transportManager: TransportManager,
    private val identityKeyStore: IdentityKeyStore,
    private val localDeviceType: DeviceType,
    private val scope: CoroutineScope,
    /** Local BLE trigger (not a message), so the transport-level feature gate can't cover it. */
    private val isEnabled: () -> Boolean = { true }
) {
    private val logic = CoreLockOnLeave(bleProximityMonitor.nearbyDeviceIds.value.toList())
    private var stateJob: kotlinx.coroutines.Job? = null

    fun start() {
        // A phone arms lock-on-leave for the computers it lists in its slot (cleared, or the phone was revoked: nothing armed).
        stateJob?.cancel()
        stateJob = scope.launch {
            transportManager.stateChanges.collect { change ->
                if (change.slot != lockOnLeaveSlot()) return@collect
                val armed = change.value?.let { runCatching { lockOnLeaveIsArmedFor(it.toString(), identityKeyStore.deviceId) }.getOrNull() } ?: false
                trustedDevicesStore.setLockOnLeaveEnabled(change.deviceId, armed)
            }
        }
        bleProximityMonitor.nearbyDeviceIds
            .onEach { handleNearbyDeviceIdsChanged(it) }
            .launchIn(scope)
        if (localDeviceType == DeviceType.ANDROID_PHONE) publishArmed()
    }

    fun stop() {
        stateJob?.cancel()
        stateJob = null
    }

    /** Phone only: publishes which computers this phone arms lock-on-leave for. Call after a toggle changes
     *  `lockOnLeaveEnabled`; the core ignores it when nothing changed. */
    fun publishArmed() {
        if (localDeviceType != DeviceType.ANDROID_PHONE) return
        val armed = trustedDevicesStore.allDevices()
            .filter { it.deviceType != DeviceType.ANDROID_PHONE && it.lockOnLeaveEnabled }
            .map { it.deviceId }
        transportManager.setState(lockOnLeaveSlot(), Json.parseToJsonElement(lockOnLeaveConfigPayload(armed)))
    }

    private fun handleNearbyDeviceIdsChanged(newValue: Set<String>) {
        val armed = trustedDevicesStore.allDevices().filter { it.lockOnLeaveEnabled }.map { it.deviceId }
        if (logic.nearbyChanged(newValue.toList(), System.currentTimeMillis(), isEnabled(), armed)) lockScreen()
    }

    /** Requires this app to already be an active device admin (see `res/xml/device_admin.xml` and the one-time
     *  `ACTION_ADD_DEVICE_ADMIN` onboarding flow in `ui/MainActivity.kt`) — `lockNow()` throws [SecurityException]
     *  otherwise, caught here rather than crashing the BLE observation loop. */
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
        val COOLDOWN_MS: Long get() = lockOnLeaveCooldownMs()

        fun adminComponentName(context: Context): ComponentName =
            ComponentName(context, ConnectDeviceAdminReceiver::class.java)
    }
}
