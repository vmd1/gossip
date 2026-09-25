package dev.vmd1.gossip.features.hotspot

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.util.Log
import dev.vmd1.gossip.crypto.IdentityKeyStore
import dev.vmd1.gossip.features.proximity.BLEProximityMonitor
import dev.vmd1.gossip.protocol.DeviceType
import dev.vmd1.gossip.protocol.Envelope
import dev.vmd1.gossip.protocol.MessageType
import dev.vmd1.gossip.transport.EnvelopeHandler
import dev.vmd1.gossip.transport.MessageRouter
import dev.vmd1.gossip.transport.TransportManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive

private const val TAG = "HotspotStateManager"

/** Whether a trusted phone's Instant Hotspot is currently on, as last reported over the
 *  mesh (`hotspot.state_update`, see `schema/message-types.md`) — not a BLE-scan-derived
 *  signal like `BLEProximityMonitor.hotspotAvailable`. `ssid` is best-effort (only
 *  present when the reporting phone could privilegedly read it; see
 *  `HotspotCredentialReader`) — the icon/UI only ever needs [enabled]. */
data class HotspotState(val enabled: Boolean, val ssid: String? = null)

/**
 * Implements `hotspot.state_update`: broadcasts this **phone's** own Instant Hotspot
 * on/off state to the whole mesh, and tracks every trusted phone's last-reported state
 * for UI (a hotspot icon next to that phone's row, on every device — Mac, tablets, and
 * other phones alike). Distinct from, and much simpler than, the BLE GATT `hotspot.
 * toggle_request`/`hotspot.status` exchange (`docs/ble-hotspot-protocol.md`) — this is a
 * live-state convenience signal for devices that already have a mesh connection to the
 * reporting phone, not a way to reach one that doesn't.
 *
 * Reporting (phone only): observes `WifiManager.WIFI_AP_STATE_CHANGED_ACTION` — a public
 * broadcast any app can register a runtime receiver for, no special permission needed to
 * *observe* it (unlike reading the SSID, which still goes through
 * [HotspotCredentialReader]'s Shizuku-gated path when available). **Reconciled**, per
 * this repo's `CLAUDE.md` convention: sent on every detected local change, plus once on
 * every fresh `CONNECTED` transition and every 60s while connected — see
 * [reportInitialSyncState]/[periodicResync], driven the same way
 * `DndSyncManager`'s/`ClipboardSyncManager`'s resync loops already are from
 * `SyncForegroundService`.
 *
 * Receiving (all device types): last-write-wins per sender, naturally idempotent —
 * re-applying an unchanged reported state is a no-op by construction, no dedupe needed.
 */
class HotspotStateManager(
    private val context: Context,
    private val identityKeyStore: IdentityKeyStore,
    private val transportManager: TransportManager,
    private val messageRouter: MessageRouter,
    private val scope: CoroutineScope,
    private val deviceType: DeviceType,
    private val shizukuManager: ShizukuManager? = null,
    private val bleProximityMonitor: BLEProximityMonitor? = null
) {
    private val _hotspotStateBySenderId = MutableStateFlow<Map<String, HotspotState>>(emptyMap())
    val hotspotStateBySenderId: StateFlow<Map<String, HotspotState>> = _hotspotStateBySenderId.asStateFlow()

    /** The state this device last reported (used to skip a redundant send on an
     *  unchanged local reading, mirroring `DndSyncManager.expectedState`). */
    private var lastReported: Boolean? = null
    private var receiverRegistered = false

    private val stateChangedReceiver = object : BroadcastReceiver() {
        override fun onReceive(receiverContext: Context, intent: Intent) {
            reportCurrentState()
        }
    }

    private val updateHandler = EnvelopeHandler { envelope ->
        val enabled = envelope.payload["enabled"]?.jsonPrimitive?.contentOrNull?.toBooleanStrictOrNull() ?: return@EnvelopeHandler
        val ssid = envelope.payload["ssid"]?.jsonPrimitive?.contentOrNull
        _hotspotStateBySenderId.value = _hotspotStateBySenderId.value + (envelope.senderId to HotspotState(enabled, ssid))
    }

    fun start() {
        messageRouter.register(MessageType.HOTSPOT_STATE_UPDATE, updateHandler)
        if (deviceType != DeviceType.ANDROID_PHONE) return
        if (!receiverRegistered) {
            // `WifiManager.WIFI_AP_STATE_CHANGED_ACTION` is `@SystemApi` — not in the
            // public SDK (same category as `getSoftApConfiguration`, see
            // `HotspotCredentialReader`'s doc comment) — but the broadcast's *action
            // string* itself is not permission-gated to receive, only the constant
            // naming it is hidden from the public SDK. Hardcoded here rather than
            // referencing the hidden constant, matching how third-party hotspot-status
            // apps commonly observe this same broadcast.
            context.registerReceiver(stateChangedReceiver, IntentFilter("android.net.wifi.WIFI_AP_STATE_CHANGED"))
            receiverRegistered = true
        }
    }

    fun stop() {
        messageRouter.unregister(updateHandler)
        if (receiverRegistered) {
            runCatching { context.unregisterReceiver(stateChangedReceiver) }
            receiverRegistered = false
        }
    }

    /** Sends this phone's real current hotspot state if it differs from [lastReported].
     *  Called on every observed `WIFI_AP_STATE_CHANGED_ACTION`. No-op on a
     *  tablet/Mac-equivalent device (never called there — see [start]). */
    fun reportCurrentState() {
        val enabled = TetherHelper.isHotspotEnabled(context)
        if (enabled == lastReported) return
        lastReported = enabled
        send(enabled)
    }

    /** Sends this phone's real current state unconditionally — call once per fresh
     *  connection (mirrors `DndSyncManager.reportInitialSyncState`) and periodically
     *  while connected (mirrors `ClipboardSyncManager`'s/`DndSyncManager`'s resync
     *  loops). Unlike [reportCurrentState], always sends: a newly-connected or
     *  previously-disconnected peer needs this regardless of whether the state itself
     *  has changed recently. */
    fun periodicResync() {
        if (deviceType != DeviceType.ANDROID_PHONE) return
        lastReported = TetherHelper.isHotspotEnabled(context)
        send(lastReported == true)
    }

    private fun send(enabled: Boolean) {
        // Same state, also carried over BLE (a second capability bit on the existing
        // proximity advertisement) — see BLEProximityMonitor.hotspotOn's doc comment
        // for why this needs to be independent of the mesh broadcast below: a peer
        // with no mesh connection to this phone at all still gets a live signal once
        // it's within BLE range, rather than being stuck with a stale last-known state
        // (or no state at all) forever.
        bleProximityMonitor?.setHotspotOn(enabled)
        val ssid = if (enabled) HotspotCredentialReader.readCredentials(context, shizukuManager)?.ssid else null
        val envelope = Envelope(
            type = MessageType.HOTSPOT_STATE_UPDATE,
            senderId = identityKeyStore.deviceId,
            broadcast = true,
            payload = buildJsonObject {
                put("enabled", JsonPrimitive(enabled))
                ssid?.let { put("ssid", JsonPrimitive(it)) }
            }
        )
        scope.launch {
            runCatching { transportManager.send(envelope) }
                .onFailure { Log.w(TAG, "Failed to send hotspot.state_update", it) }
        }
    }
}
