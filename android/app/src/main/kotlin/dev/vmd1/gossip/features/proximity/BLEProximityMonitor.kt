package dev.vmd1.gossip.features.proximity

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import dev.vmd1.gossip.util.Log
import androidx.core.content.ContextCompat
import dev.vmd1.gossip.crypto.IdentityKeyStore
import dev.vmd1.gossip.crypto.TrustedDevicesStore
import dev.vmd1.gossip.protocol.DeviceType
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap

/**
 * Detects when a specific trusted device is within confirmed BLE range — the shared
 * primitive behind lock-on-leave and Instant Hotspot (see `docs/ble-proximity-protocol.md`
 * for the wire-level advertisement format and threshold rationale). Generic over
 * [DeviceType] in spirit even though, today, only two roles exist: phones advertise,
 * everything else (tablets today; a future WearOS watch could go either way) scans.
 *
 * "Confirmed" means 2 consecutive advertisements at RSSI >= [RSSI_THRESHOLD] before a
 * device is reported nearby, and [LOSS_TIMEOUT_MS] of silence before it's reported as
 * having left — a single strong or weak reading never flips [nearbyDeviceIds] on its
 * own. See the protocol doc for why: Wi-Fi connection drops are common and unrelated to
 * physical distance, so this primitive exists specifically to *not* share that noisiness.
 */
class BLEProximityMonitor(
    private val context: Context,
    private val identityKeyStore: IdentityKeyStore,
    private val trustedDevicesStore: TrustedDevicesStore,
    private val deviceType: DeviceType
) {
    private val _nearbyDeviceIds = MutableStateFlow<Set<String>>(emptySet())
    val nearbyDeviceIds: StateFlow<Set<String>> = _nearbyDeviceIds.asStateFlow()

    private val bluetoothAdapter = context.getSystemService(BluetoothManager::class.java)?.adapter
    private val mainHandler = Handler(Looper.getMainLooper())

    /** Currently acceptable keyed beacon tags (hex) -> device; rebuilt when the roster/keys change and as the time window moves. */
    @Volatile private var fingerprintToDeviceId: Map<String, String> = emptyMap()
    @Volatile private var tagMapWindow = -1L
    private val states = ConcurrentHashMap<String, ProximityState>()
    private var scanCallback: ScanCallback? = null
    private var advertiseCallback: AdvertiseCallback? = null
    private var isRunning = false

    /** Whether this device (only meaningful for a phone — the only role that ever
     *  advertises) currently offers itself as an Instant Hotspot source — mirrors
     *  `OnboardingPreferences.provideHotspotEnabled`, kept in sync via
     *  [setHotspotAvailable] rather than read live from prefs on every advertise
     *  restart, so this class stays free of an `OnboardingPreferences` dependency. */
    @Volatile
    private var hotspotAvailable = false

    /** Whether this device's Instant Hotspot is *currently on* right now — distinct from
     *  [hotspotAvailable] (which just means "willing to provide if asked"). Kept in sync
     *  via [setHotspotOn], called from `HotspotStateManager`'s own `WIFI_AP_STATE_
     *  CHANGED_ACTION` observer so there's exactly one place watching that broadcast.
     *  Carried in the same advertisement capability byte as [hotspotAvailable] (a
     *  second bit) specifically so a peer's on/off indicator stays live over BLE alone
     *  — confirmed live as a real gap otherwise: `hotspot.state_update` (the mesh
     *  broadcast, `schema/message-types.md`) is the richer signal (works at any range,
     *  carries the SSID) but goes stale the moment the mesh connection drops, with
     *  nothing to correct it until reconnected; BLE has no such dependency, since it
     *  never needed a Wi-Fi/mesh connection in the first place. */
    @Volatile
    private var hotspotOn = false

    /** Last-observed "hotspot available" (bit 0) / "hotspot on" (bit 1) capability
     *  flags per scanned `deviceId` (see the advertisement payload's capability byte
     *  below) — not gated on proximity confirmation like [nearbyDeviceIds], since a
     *  capability signal doesn't need the same debounce a presence signal does;
     *  combine with [nearbyDeviceIds] (or a [startHotspotRequestScan] result set) to
     *  answer "is this specific *nearby* device offering/running hotspot right now."
     *  Cleared for a device the moment it's no longer confirmed nearby, so a stale
     *  claim can't linger after it actually leaves. */
    private val hotspotCapabilityByDeviceId = ConcurrentHashMap<String, Boolean>()

    /** Same signal as [hotspotCapabilityByDeviceId] but for the "hotspot currently on"
     *  bit, backed by a [StateFlow] rather than a plain map — live-confirmed real gap
     *  otherwise: a plain `ConcurrentHashMap` mutation is invisible to Compose's
     *  snapshot-state system, so the paired-devices UI only ever picked up a fresh
     *  value as an incidental side effect of some *other* recomposition trigger (e.g.
     *  [nearbyDeviceIds] changing on an enter/leave-range transition), making the
     *  on/off icon feel like it updated far less often than the same signal on Mac
     *  (whose SwiftUI shell just happens to re-render often enough from unrelated
     *  activity to mask the same underlying gap). [isHotspotOn] remains for a one-shot
     *  read; UI should `collectAsState()` [hotspotOnByDeviceId] instead for a live
     *  binding. */
    private val _hotspotOnByDeviceId = MutableStateFlow<Map<String, Boolean>>(emptyMap())
    val hotspotOnByDeviceId: StateFlow<Map<String, Boolean>> = _hotspotOnByDeviceId.asStateFlow()

    /** Most recently observed [BluetoothDevice] handle per `deviceId` — see
     *  [bluetoothDevice]. */
    private val bluetoothDeviceByDeviceId = ConcurrentHashMap<String, BluetoothDevice>()

    /** Separate scanner handle for [startHotspotRequestScan] — deliberately not shared
     *  with [scanCallback]/[startScanning], since a **phone** (which normally only ever
     *  advertises, per the role split below) can run this on demand *in addition to*
     *  its own advertising, to look for a nearby phone offering Instant Hotspot. See
     *  the "any device without internet should be able to request... from any nearby
     *  opted-in phone" requirement in `docs/ble-hotspot-protocol.md`'s handoff notes —
     *  this is the phone-as-requester half of that; Mac/tablets need no equivalent
     *  extra scan since they already scan continuously as their normal role. */
    private var requestScanCallback: ScanCallback? = null
    private val _hotspotRequestScanResults = MutableStateFlow<Set<String>>(emptySet())
    /** `deviceId`s of trusted phones currently observed (during an active
     *  [startHotspotRequestScan]) advertising the hotspot-available capability bit.
     *  Empty whenever no request scan is running. */
    val hotspotRequestScanResults: StateFlow<Set<String>> = _hotspotRequestScanResults.asStateFlow()

    /** Restarts advertising/scanning whenever the Bluetooth radio itself comes back on —
     *  confirmed necessary live: toggling Bluetooth off and back on (not just leaving/
     *  re-entering range with the radio always on) invalidates the previous
     *  `BluetoothLeAdvertiser`/`BluetoothLeScanner` instance, and without this listener
     *  the phone/tablet silently never resumes its role until the app itself restarts,
     *  even though [start] was called successfully the first time. */
    private val radioStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)
            if (state == BluetoothAdapter.STATE_ON && isRunning) {
                startRole()
            }
        }
    }

    private val staleCheckRunnable = object : Runnable {
        override fun run() {
            checkForStaleDevices()
            mainHandler.postDelayed(this, STALE_CHECK_INTERVAL_MS)
        }
    }

    private data class ProximityState(
        var consecutiveStrongHits: Int = 0,
        var lastSeenAtMs: Long = 0L,
        var isInRange: Boolean = false
    )

    /** Starts this device's role (advertise if a phone, scan otherwise). No-ops if the
     *  required Bluetooth permission for that role isn't granted — callers should check
     *  [hasRequiredPermissions] first and prompt the user if not, but this never crashes
     *  on a missing permission either way. */
    fun start() {
        isRunning = true
        rebuildFingerprintMap()
        startRole()
        context.registerReceiver(radioStateReceiver, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED))
        mainHandler.postDelayed(staleCheckRunnable, STALE_CHECK_INTERVAL_MS)
    }

    fun stop() {
        isRunning = false
        stopAdvertising()
        stopScanning()
        stopHotspotRequestScan()
        runCatching { context.unregisterReceiver(radioStateReceiver) }
        mainHandler.removeCallbacks(staleCheckRunnable)
    }

    private fun startRole() {
        when (deviceType) {
            DeviceType.ANDROID_PHONE -> startAdvertising()
            else -> startScanning()
        }
    }

    /** Re-derives the acceptable beacon tags of every trusted device that has shared its beacon key.
     *  Called on [start], when a peer's key arrives, and whenever the 2-minute tag window has moved on
     *  (see [deviceIdForTag]); callers should also call it after pairing a new device. */
    fun rebuildFingerprintMap() {
        val map = HashMap<String, String>()
        for (device in trustedDevicesStore.allDevices()) {
            val key = device.beaconKey ?: continue
            for (tag in BeaconTag.acceptableTags(key)) map[tag.toHex()] = device.deviceId
        }
        fingerprintToDeviceId = map
        tagMapWindow = BeaconTag.window()
    }

    private fun deviceIdForTag(tagHex: String): String? {
        if (BeaconTag.window() != tagMapWindow) rebuildFingerprintMap()
        return fingerprintToDeviceId[tagHex]
    }

    fun hasRequiredPermissions(): Boolean {
        val permission = when (deviceType) {
            DeviceType.ANDROID_PHONE -> Manifest.permission.BLUETOOTH_ADVERTISE
            else -> Manifest.permission.BLUETOOTH_SCAN
        }
        return ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
    }

    @SuppressLint("MissingPermission") // checked via hasRequiredPermissions() before every call
    private fun startAdvertising() {
        val advertiser = bluetoothAdapter?.bluetoothLeAdvertiser
        if (advertiser == null || !hasRequiredPermissions()) {
            Log.w(TAG, "Cannot advertise: no BLE advertiser or missing BLUETOOTH_ADVERTISE permission")
            return
        }

        val fingerprint = BeaconTag.tag(identityKeyStore.beaconKey, BeaconTag.window())
        // Byte 10: capability flags. Bit 0 = hotspot available (willing to provide),
        // bit 1 = hotspot currently on. A single extra byte fits comfortably in the
        // legacy 31-byte budget alongside the existing 14-byte AD structure (see
        // docs/ble-proximity-protocol.md's budget math) — no need for a second AD
        // structure or a GATT connection just to advertise these bits, which is the
        // whole point: a requester can see "does this nearby phone offer/currently run
        // hotspot" from the scan alone, and — unlike `hotspot.state_update`'s mesh
        // broadcast — this stays live even when there's no mesh connection at all.
        var capabilityFlagsInt = 0
        if (hotspotAvailable) capabilityFlagsInt = capabilityFlagsInt or CAPABILITY_HOTSPOT_AVAILABLE.toInt()
        if (hotspotOn) capabilityFlagsInt = capabilityFlagsInt or CAPABILITY_HOTSPOT_ON.toInt()
        val capabilityFlags = capabilityFlagsInt.toByte()
        val manufacturerData = MAGIC + fingerprint + byteArrayOf(capabilityFlags)

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(false)
            .build()
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addManufacturerData(MANUFACTURER_ID, manufacturerData)
            .build()

        val callback = object : AdvertiseCallback() {
            override fun onStartFailure(errorCode: Int) {
                Log.w(TAG, "BLE advertise failed to start: error $errorCode")
            }
        }
        advertiseCallback = callback
        advertiser.startAdvertising(settings, data, callback)
        // The tag is only valid for its window: re-arm with the next one when it ends.
        mainHandler.removeCallbacks(rotateAdvertisingRunnable)
        mainHandler.postDelayed(rotateAdvertisingRunnable, BeaconTag.millisUntilNextWindow() + 1)
    }

    /** Called from the "Provide Instant Hotspot" toggle (phone-only UI). Restarts
     *  advertising immediately so the capability bit change is reflected on the air
     *  right away, rather than waiting for the next natural advertise restart (e.g. a
     *  Bluetooth radio cycle). No-ops (beyond updating the flag) if this device isn't
     *  currently advertising — [startAdvertising] reads the current [hotspotAvailable]
     *  value the next time it runs regardless. Idempotent: calling with the same value
     *  twice just re-advertises the same payload. */
    fun setHotspotAvailable(enabled: Boolean) {
        if (hotspotAvailable == enabled) return
        hotspotAvailable = enabled
        if (isRunning && deviceType == DeviceType.ANDROID_PHONE) {
            stopAdvertising()
            startAdvertising()
        }
    }

    /** Called from `HotspotStateManager`'s `WIFI_AP_STATE_CHANGED_ACTION` observer
     *  whenever this phone's actual hotspot on/off state changes — see [hotspotOn]'s
     *  doc comment for why this needs to be a BLE signal too, not just the mesh
     *  broadcast. Same restart-advertising-immediately/idempotent contract as
     *  [setHotspotAvailable]. */
    fun setHotspotOn(enabled: Boolean) {
        if (hotspotOn == enabled) return
        hotspotOn = enabled
        if (isRunning && deviceType == DeviceType.ANDROID_PHONE) {
            stopAdvertising()
            startAdvertising()
        }
    }

    private val rotateAdvertisingRunnable = Runnable {
        if (isRunning && deviceType == DeviceType.ANDROID_PHONE) {
            stopAdvertising()
            startAdvertising()
        }
    }

    @SuppressLint("MissingPermission")
    private fun stopAdvertising() {
        mainHandler.removeCallbacks(rotateAdvertisingRunnable)
        val advertiser = bluetoothAdapter?.bluetoothLeAdvertiser ?: return
        advertiseCallback?.let { advertiser.stopAdvertising(it) }
        advertiseCallback = null
    }

    @SuppressLint("MissingPermission")
    private fun startScanning() {
        val scanner = bluetoothAdapter?.bluetoothLeScanner
        if (scanner == null || !hasRequiredPermissions()) {
            Log.w(TAG, "Cannot scan: no BLE scanner or missing BLUETOOTH_SCAN permission")
            return
        }

        // Matches the magic prefix and ignores the fingerprint suffix (mask = 0x00 over
        // those bytes), so one filter catches every Connect phone, not just trusted ones —
        // matching against TrustedDevices happens in onScanResult.
        val filter = ScanFilter.Builder()
            .setManufacturerData(
                MANUFACTURER_ID,
                MAGIC + ByteArray(8),
                byteArrayOf(0xFF.toByte(), 0xFF.toByte()) + ByteArray(8)
            )
            .build()
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()

        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                handleScanResult(result)
            }

            override fun onScanFailed(errorCode: Int) {
                Log.w(TAG, "BLE scan failed to start: error $errorCode")
            }
        }
        scanCallback = callback
        scanner.startScan(listOf(filter), settings, callback)
    }

    @SuppressLint("MissingPermission")
    private fun stopScanning() {
        val scanner = bluetoothAdapter?.bluetoothLeScanner ?: return
        scanCallback?.let { scanner.stopScan(it) }
        scanCallback = null
    }

    private fun handleScanResult(result: ScanResult) {
        val data = result.scanRecord?.getManufacturerSpecificData(MANUFACTURER_ID) ?: return
        if (data.size < 10 || data[0] != MAGIC[0] || data[1] != MAGIC[1]) return
        val fingerprint = data.copyOfRange(2, 10).toHex()
        val deviceId = deviceIdForTag(fingerprint) ?: return
        // Byte 10 (capability flags) is optional on the wire — a peer running an older
        // build simply won't have it, which must not be treated as a malformed
        // advertisement (the `data.size < 10` guard above already covers the fields
        // that *are* required).
        if (data.size >= 11) {
            hotspotCapabilityByDeviceId[deviceId] = (data[10].toInt() and CAPABILITY_HOTSPOT_AVAILABLE.toInt()) != 0
            setHotspotOnForDevice(deviceId, (data[10].toInt() and CAPABILITY_HOTSPOT_ON.toInt()) != 0)
        }
        bluetoothDeviceByDeviceId[deviceId] = result.device
        recordDetection(deviceId, result.rssi)
    }

    private fun setHotspotOnForDevice(deviceId: String, on: Boolean) {
        _hotspotOnByDeviceId.value = _hotspotOnByDeviceId.value + (deviceId to on)
    }

    private fun removeHotspotOnForDevice(deviceId: String) {
        _hotspotOnByDeviceId.value = _hotspotOnByDeviceId.value - deviceId
    }

    /** The most recently observed [BluetoothDevice] for [deviceId] — needed to open an
     *  actual GATT connection ([dev.vmd1.gossip.features.hotspot.HotspotGattClient]) once a
     *  caller decides, from [hotspotAvailable], that it wants to. Unlike a plain scan
     *  filter match, a [BluetoothDevice] handle is reusable across `connectGatt` calls
     *  regardless of which scanner instance observed it — no manager-scoping issue like
     *  Mac's `CBPeripheral`/`CBCentralManager`. */
    fun bluetoothDevice(deviceId: String): BluetoothDevice? = bluetoothDeviceByDeviceId[deviceId]

    /** Whether [deviceId] was last observed advertising the hotspot-available
     *  capability bit. Meaningful only while [deviceId] is actually in
     *  [nearbyDeviceIds] (or a [startHotspotRequestScan] result set) — this map itself
     *  isn't proximity-debounced, only cleared on confirmed range-loss (see
     *  [checkForStaleDevices]). */
    fun hotspotAvailable(deviceId: String): Boolean = hotspotCapabilityByDeviceId[deviceId] == true

    /** Whether [deviceId] was last observed advertising the "hotspot currently on" bit
     *  — a BLE-only signal, independent of `hotspot.state_update`'s mesh broadcast, so
     *  it stays accurate even when this device has no mesh connection to [deviceId] at
     *  all. Same proximity-scoping caveat as [hotspotAvailable]. */
    fun isHotspotOn(deviceId: String): Boolean = hotspotOnByDeviceId.value[deviceId] == true

    private fun recordDetection(deviceId: String, rssi: Int) {
        val state = states.getOrPut(deviceId) { ProximityState() }
        synchronized(state) {
            // lastSeenAtMs only advances on readings that clear the RSSI floor — a device
            // right at the boundary keeps advertising at a weak-but-nonzero RSSI, and if
            // *any* reception counted as "seen" the loss-timeout would never fire no
            // matter how weak the signal got. Weak and absent signal both need to count
            // the same way toward "leaving." See BLEProximityMonitor.swift for the Mac
            // side of this same fix.
            if (rssi >= RSSI_THRESHOLD) {
                state.lastSeenAtMs = System.currentTimeMillis()
                state.consecutiveStrongHits += 1
            } else {
                state.consecutiveStrongHits = 0
            }

            if (!state.isInRange && state.consecutiveStrongHits >= CONFIRM_HIT_COUNT) {
                state.isInRange = true
                _nearbyDeviceIds.value = _nearbyDeviceIds.value + deviceId
            }
        }
    }

    private fun checkForStaleDevices() {
        val now = System.currentTimeMillis()
        for ((deviceId, state) in states) {
            synchronized(state) {
                if (state.isInRange && now - state.lastSeenAtMs > LOSS_TIMEOUT_MS) {
                    state.isInRange = false
                    state.consecutiveStrongHits = 0
                    _nearbyDeviceIds.value = _nearbyDeviceIds.value - deviceId
                    hotspotCapabilityByDeviceId.remove(deviceId)
                    removeHotspotOnForDevice(deviceId)
                    bluetoothDeviceByDeviceId.remove(deviceId)
                }
            }
        }
    }

    /** Starts an on-demand secondary scan for nearby phones advertising the
     *  hotspot-available capability bit — the phone-as-requester half of Instant
     *  Hotspot's multi-device support (see the class doc on [requestScanCallback]).
     *  Safe to call regardless of this device's own [deviceType]/role: a phone that's
     *  already advertising can run this concurrently (Android supports simultaneous
     *  central+peripheral BLE roles), and a Mac/tablet that's already continuously
     *  scanning as its normal role gets no benefit from calling this (its existing
     *  scan + [hotspotAvailable] already answers the same question) but it's harmless
     *  to call anyway. No-ops if [hasRequiredPermissions] (`BLUETOOTH_SCAN`) isn't
     *  granted or a scan is already running. Caller owns the lifecycle — call
     *  [stopHotspotRequestScan] once the requesting UI is done (e.g. screen closed or
     *  a target was picked), rather than leaving this running indefinitely; unlike the
     *  primary advertise/scan role, this isn't meant to run for the app's whole
     *  lifetime. */
    @SuppressLint("MissingPermission")
    fun startHotspotRequestScan() {
        if (requestScanCallback != null) return
        val scanner = bluetoothAdapter?.bluetoothLeScanner
        if (scanner == null || ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_SCAN) != PackageManager.PERMISSION_GRANTED) {
            Log.w(TAG, "Cannot start hotspot request scan: no BLE scanner or missing BLUETOOTH_SCAN permission")
            return
        }
        val filter = ScanFilter.Builder()
            .setManufacturerData(
                MANUFACTURER_ID,
                MAGIC + ByteArray(8),
                byteArrayOf(0xFF.toByte(), 0xFF.toByte()) + ByteArray(8)
            )
            .build()
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val data = result.scanRecord?.getManufacturerSpecificData(MANUFACTURER_ID) ?: return
                if (data.size < 11 || data[0] != MAGIC[0] || data[1] != MAGIC[1]) return
                if (result.rssi < RSSI_THRESHOLD) return
                val fingerprint = data.copyOfRange(2, 10).toHex()
                val deviceId = deviceIdForTag(fingerprint) ?: return
                val hotspotAvailable = (data[10].toInt() and CAPABILITY_HOTSPOT_AVAILABLE.toInt()) != 0
                hotspotCapabilityByDeviceId[deviceId] = hotspotAvailable
                setHotspotOnForDevice(deviceId, (data[10].toInt() and CAPABILITY_HOTSPOT_ON.toInt()) != 0)
                bluetoothDeviceByDeviceId[deviceId] = result.device
                _hotspotRequestScanResults.value = if (hotspotAvailable) {
                    _hotspotRequestScanResults.value + deviceId
                } else {
                    _hotspotRequestScanResults.value - deviceId
                }
            }

            override fun onScanFailed(errorCode: Int) {
                Log.w(TAG, "Hotspot request scan failed to start: error $errorCode")
            }
        }
        requestScanCallback = callback
        scanner.startScan(listOf(filter), settings, callback)
    }

    @SuppressLint("MissingPermission")
    fun stopHotspotRequestScan() {
        val scanner = bluetoothAdapter?.bluetoothLeScanner
        requestScanCallback?.let { scanner?.stopScan(it) }
        requestScanCallback = null
        _hotspotRequestScanResults.value = emptySet()
    }

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

    companion object {
        private const val TAG = "BLEProximityMonitor"
        const val MANUFACTURER_ID = 0xFFFF
        val MAGIC = byteArrayOf(0x43, 0x6E) // ASCII "Cn"
        const val RSSI_THRESHOLD = -75
        const val CONFIRM_HIT_COUNT = 2
        const val CAPABILITY_HOTSPOT_AVAILABLE: Byte = 0x01
        const val CAPABILITY_HOTSPOT_ON: Byte = 0x02
        const val LOSS_TIMEOUT_MS = 6_000L
        private const val STALE_CHECK_INTERVAL_MS = 1_000L
    }
}
