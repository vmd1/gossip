package dev.vmd1.gossip.features.hotspot

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import dev.vmd1.gossip.util.Log
import dev.vmd1.gossip.crypto.IdentityKeyStore
import dev.vmd1.gossip.features.proximity.BLEProximityMonitor
import dev.vmd1.gossip.protocol.DeviceType
import dev.vmd1.gossip.transport.TransportManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import uniffi.gossip_ffi.HotspotStates as CoreHotspotStates
import uniffi.gossip_ffi.hotspotSlot
import uniffi.gossip_ffi.hotspotStatePayload

private const val TAG = "HotspotStateManager"

/** Whether a trusted phone's Instant Hotspot is currently on, as last reported over the mesh (the `hotspot.state` state slot,
 *  see `schema/message-types.md`) — not a BLE-scan-derived signal like `BLEProximityMonitor.hotspotAvailable`. `ssid` is
 *  best-effort (only present when the reporting phone could privilegedly read it; see `HotspotCredentialReader`) — the
 *  icon/UI only ever needs [enabled]. */
data class HotspotState(val enabled: Boolean, val ssid: String? = null)

/**
 * Implements the `hotspot.state` state slot: publishes this **phone's** own Instant Hotspot on/off state, and tracks every
 * trusted phone's last-reported state for UI (a hotspot icon next to that phone's row, on every device — Mac, tablets, and
 * other phones alike). Distinct from, and much simpler than, the BLE GATT `hotspot.toggle_request`/`hotspot.status`
 * exchange (`docs/ble-hotspot-protocol.md`) — this is a live-state convenience signal for devices that already have a mesh
 * connection to the reporting phone, not a way to reach one that doesn't.
 *
 * Reporting (phone only): observes `WifiManager.WIFI_AP_STATE_CHANGED_ACTION` — a public broadcast any app can register a
 * runtime receiver for, no special permission needed to *observe* it (unlike reading the SSID, which still goes through
 * [HotspotCredentialReader]'s Shizuku-gated path when available). The core's state sync (`docs/plans/state-sync.md`) sends
 * the slot to every device that connects later and repairs it periodically, so nothing here resends it.
 *
 * Receiving (all device types): last-write-wins per sender, idempotent — the per-sender map is the core's `HotspotStates`.
 */
class HotspotStateManager(
    private val context: Context,
    private val identityKeyStore: IdentityKeyStore,
    private val transportManager: TransportManager,
    private val scope: CoroutineScope,
    private val deviceType: DeviceType,
    private val shizukuManager: ShizukuManager? = null,
    private val bleProximityMonitor: BLEProximityMonitor? = null
) {
    private val _hotspotStateBySenderId = MutableStateFlow<Map<String, HotspotState>>(emptyMap())
    val hotspotStateBySenderId: StateFlow<Map<String, HotspotState>> = _hotspotStateBySenderId.asStateFlow()

    private val logic = CoreHotspotStates()
    private var collecting: kotlinx.coroutines.Job? = null

    /** The state this device last reported (skips a redundant publish on an unchanged local reading). */
    private var lastReported: Boolean? = null
    private var receiverRegistered = false

    private val stateChangedReceiver = object : BroadcastReceiver() {
        override fun onReceive(receiverContext: Context, intent: Intent) {
            reportCurrentState()
        }
    }

    fun start() {
        collecting?.cancel()
        collecting = scope.launch {
            transportManager.stateChanges.collect { change ->
                if (change.slot == hotspotSlot()) handleSlot(change.deviceId, change.value?.toString())
            }
        }
        if (deviceType != DeviceType.ANDROID_PHONE) return
        if (!receiverRegistered) {
            // `WifiManager.WIFI_AP_STATE_CHANGED_ACTION` is `@SystemApi` — not in the public SDK (same category as
            // `getSoftApConfiguration`, see `HotspotCredentialReader`'s doc comment) — but the broadcast's *action string*
            // itself is not permission-gated to receive, only the constant naming it is hidden from the public SDK.
            // Hardcoded here rather than referencing the hidden constant, matching how third-party hotspot-status apps
            // commonly observe this same broadcast.
            context.registerReceiver(stateChangedReceiver, IntentFilter("android.net.wifi.WIFI_AP_STATE_CHANGED"))
            receiverRegistered = true
        }
        reportCurrentState()
    }

    fun stop() {
        collecting?.cancel()
        collecting = null
        if (receiverRegistered) {
            runCatching { context.unregisterReceiver(stateChangedReceiver) }
            receiverRegistered = false
        }
    }

    /** Publishes this phone's real current hotspot state if it differs from [lastReported]. Called on every observed
     *  `WIFI_AP_STATE_CHANGED_ACTION` and once at start. No-op on a tablet (never called there — see [start]). */
    fun reportCurrentState() {
        val enabled = TetherHelper.isHotspotEnabled(context)
        if (enabled == lastReported) return
        lastReported = enabled
        publish(enabled)
    }

    private fun publish(enabled: Boolean) {
        // Same state, also carried over BLE (a second capability bit on the existing proximity advertisement) — see
        // BLEProximityMonitor.hotspotOn's doc comment for why this needs to be independent of the mesh slot: a peer with no
        // mesh connection to this phone at all still gets a live signal once it's within BLE range, rather than being stuck
        // with a stale last-known state (or no state at all) forever.
        bleProximityMonitor?.setHotspotOn(enabled)
        val ssid = if (enabled) HotspotCredentialReader.readCredentials(context, shizukuManager)?.ssid else null
        transportManager.setState(hotspotSlot(), Json.parseToJsonElement(hotspotStatePayload(enabled, ssid)))
    }

    /** A phone's `hotspot.state` slot changed (`null`: cleared, or the device was revoked). */
    fun handleSlot(sender: String, value: kotlinx.serialization.json.JsonElement?) = handleSlot(sender, value?.toString())

    private fun handleSlot(sender: String, valueJson: String?) {
        if (valueJson == null) {
            logic.forget(sender)
            _hotspotStateBySenderId.value = _hotspotStateBySenderId.value - sender
            return
        }
        if (runCatching { logic.onUpdate(sender, valueJson) }.isFailure) {
            Log.w(TAG, "Bad hotspot.state from $sender")
            return
        }
        logic.stateOf(sender)?.let {
            _hotspotStateBySenderId.value = _hotspotStateBySenderId.value + (sender to HotspotState(it.enabled, it.ssid))
        }
    }
}
