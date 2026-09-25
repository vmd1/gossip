package dev.vmd1.gossip.features.hotspot

import android.content.Context
import android.util.Log
import dev.vmd1.gossip.crypto.IdentityKeyStore
import dev.vmd1.gossip.crypto.TrustedDevicesStore
import dev.vmd1.gossip.features.proximity.BLEProximityMonitor
import dev.vmd1.gossip.onboarding.OnboardingPreferences
import dev.vmd1.gossip.protocol.DeviceType
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

private const val TAG = "AutoHotspotRequestManager"

/**
 * The automatic half of Instant Hotspot (see `docs/ble-hotspot-protocol.md`'s "Not yet
 * built" section, now built): when [WanReachabilityMonitor] reports this device has been
 * offline for a while, automatically fires the same signed `hotspot.toggle_request` GATT
 * flow the manual "Request Hotspot" button uses ([HotspotGattClient.requestToggle]) against
 * a nearby, eligible, opted-in phone — no user tap needed.
 *
 * Two separate opt-in gates, both local-only and never sent over the wire (matching
 * `TrustedDevice.fallbackHost`'s precedent, per the handoff's own read of
 * `hotspot.auto_config`'s original design intent):
 * - [OnboardingPreferences.autoRequestHotspotEnabled] — whether *this* device auto-requests
 *   at all.
 * - [TrustedDevice.autoHotspotRequestEligible] — per trusted phone, whether it's a
 *   candidate target (a user might trust several phones but only want auto-request
 *   against their own).
 *
 * Candidate selection: any nearby (or, for a requesting **phone**, on-demand-scan-visible —
 * see [BLEProximityMonitor.startHotspotRequestScan]) trusted phone that's currently
 * advertising the hotspot-available capability bit, isn't already showing hotspot-on, and
 * has the per-phone eligibility flag set. First match wins — deliberately no fancier
 * tiebreak, per the handoff's own "don't over-design this."
 *
 * A cooldown after each attempt (success or failure) prevents a flapping WAN connection
 * from re-firing a fresh request every offline episode in quick succession; only one
 * request is ever in flight at a time, mirroring the manual button's own single-request
 * assumption ([dev.vmd1.gossip.ui.MainActivity.requestHotspot]).
 *
 * Deliberately does **not** auto-*turn off* the hotspot once back online — not specified by
 * the handoff, and auto-shutoff has its own false-negative risk (a brief WAN blip
 * shouldn't yank a hotspot connection out from under active use). The manual toggle/icon
 * still controls turning it off.
 */
class AutoHotspotRequestManager(
    private val context: Context,
    private val identityKeyStore: IdentityKeyStore,
    private val trustedDevicesStore: TrustedDevicesStore,
    private val bleProximityMonitor: BLEProximityMonitor,
    private val onboardingPreferences: OnboardingPreferences,
    private val deviceType: DeviceType,
    private val scope: CoroutineScope
) {
    private val wanReachabilityMonitor = WanReachabilityMonitor(scope)
    private var lastAttemptAtMs = 0L
    private var attemptInFlight = false
    private var activeConnection: android.net.ConnectivityManager.NetworkCallback? = null

    fun start() {
        wanReachabilityMonitor.wentOffline
            .onEach { onWentOffline() }
            .launchIn(scope)
        wanReachabilityMonitor.start()
    }

    private fun onWentOffline() {
        if (!onboardingPreferences.autoRequestHotspotEnabled) return
        if (attemptInFlight) return
        val now = System.currentTimeMillis()
        if (now - lastAttemptAtMs < COOLDOWN_MS) return
        scope.launch { attemptAutoRequest() }
    }

    private suspend fun attemptAutoRequest() {
        attemptInFlight = true
        lastAttemptAtMs = System.currentTimeMillis()
        try {
            val candidateId = findCandidate()
            if (candidateId == null) {
                Log.i(TAG, "Went offline but no eligible nearby phone to auto-request hotspot from")
                return
            }
            val bluetoothDevice = bleProximityMonitor.bluetoothDevice(candidateId)
            if (bluetoothDevice == null) {
                Log.w(TAG, "Candidate $candidateId had no BluetoothDevice handle by the time of the attempt")
                return
            }
            Log.i(TAG, "Auto-requesting Instant Hotspot from $candidateId")
            val client = HotspotGattClient(context, identityKeyStore, trustedDevicesStore)
            when (val result = client.requestToggle(bluetoothDevice, candidateId, enable = true)) {
                is HotspotGattClient.Result.Failed -> Log.w(TAG, "Auto hotspot request failed: ${result.reason}")
                is HotspotGattClient.Result.Success -> handleSuccess(result)
            }
        } finally {
            attemptInFlight = false
        }
    }

    private fun handleSuccess(result: HotspotGattClient.Result.Success) {
        if (!result.enabled) {
            Log.i(TAG, "Auto hotspot request declined by the provider")
            return
        }
        val ssid = result.ssid
        val passphrase = result.passphrase
        if (ssid == null || passphrase == null) {
            Log.i(TAG, "Provider turned hotspot on but credentials weren't available to auto-connect")
            return
        }
        activeConnection?.let { HotspotAutoConnect.disconnect(context, it) }
        activeConnection = HotspotAutoConnect.connect(context, ssid, passphrase) { connected ->
            Log.i(TAG, if (connected) "Auto-connected to $ssid" else "Could not auto-connect to $ssid")
        }
    }

    /** Mac/tablet already scan continuously, so [BLEProximityMonitor.nearbyDeviceIds]
     *  alone answers "which nearby trusted phone offers hotspot." A requesting **phone**
     *  has no equivalent continuous scan (see `docs/ble-proximity-protocol.md`'s role
     *  split) — it runs [BLEProximityMonitor.startHotspotRequestScan] for a bounded
     *  window instead, exactly like a phone requesting from another phone via the manual
     *  UI would, then tears it back down rather than leaving it running indefinitely. */
    private suspend fun findCandidate(): String? {
        if (deviceType == DeviceType.ANDROID_PHONE) {
            bleProximityMonitor.startHotspotRequestScan()
            try {
                withTimeoutOrNull(SCAN_WINDOW_MS) {
                    // Poll rather than collect: a match is a dictionary lookup against an
                    // already-updating StateFlow, and we only need the first snapshot
                    // that contains one, not every intermediate emission.
                    while (bleProximityMonitor.hotspotRequestScanResults.value.none { isEligibleCandidate(it) }) {
                        kotlinx.coroutines.delay(200)
                    }
                }
                return bleProximityMonitor.hotspotRequestScanResults.value.firstOrNull { isEligibleCandidate(it) }
            } finally {
                bleProximityMonitor.stopHotspotRequestScan()
            }
        }
        return bleProximityMonitor.nearbyDeviceIds.value.firstOrNull { isEligibleCandidate(it) }
    }

    private fun isEligibleCandidate(deviceId: String): Boolean {
        if (!bleProximityMonitor.hotspotAvailable(deviceId)) return false
        if (bleProximityMonitor.isHotspotOn(deviceId)) return false
        val device = trustedDevicesStore.getDevice(deviceId) ?: return false
        if (device.deviceType != DeviceType.ANDROID_PHONE) return false
        return device.autoHotspotRequestEligible
    }

    companion object {
        private const val COOLDOWN_MS = 60_000L
        private const val SCAN_WINDOW_MS = 8_000L
    }
}
