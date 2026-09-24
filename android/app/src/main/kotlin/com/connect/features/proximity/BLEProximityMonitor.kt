package com.connect.features.proximity

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
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
import android.util.Log
import androidx.core.content.ContextCompat
import com.connect.crypto.IdentityKeyStore
import com.connect.crypto.TrustedDevicesStore
import com.connect.protocol.DeviceType
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

    private var fingerprintToDeviceId: Map<String, String> = emptyMap()
    private val states = ConcurrentHashMap<String, ProximityState>()
    private var scanCallback: ScanCallback? = null
    private var advertiseCallback: AdvertiseCallback? = null
    private var isRunning = false

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
        runCatching { context.unregisterReceiver(radioStateReceiver) }
        mainHandler.removeCallbacks(staleCheckRunnable)
    }

    private fun startRole() {
        when (deviceType) {
            DeviceType.ANDROID_PHONE -> startAdvertising()
            else -> startScanning()
        }
    }

    /** Re-derives the fingerprint of every trusted device from its already-stored public
     *  key. Called on [start]; callers should call it again after pairing a new device
     *  while already running (the roster changes far less often than proximity events). */
    fun rebuildFingerprintMap() {
        fingerprintToDeviceId = trustedDevicesStore.allDevices().associate { device ->
            val digest = MessageDigest.getInstance("SHA-256").digest(device.publicKey)
            digest.copyOfRange(0, 8).toHex() to device.deviceId
        }
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

        val fingerprint = MessageDigest.getInstance("SHA-256")
            .digest(identityKeyStore.x25519KeyPair.publicKey)
            .copyOfRange(0, 8)
        val manufacturerData = MAGIC + fingerprint

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
    }

    @SuppressLint("MissingPermission")
    private fun stopAdvertising() {
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
        val deviceId = fingerprintToDeviceId[fingerprint] ?: return
        recordDetection(deviceId, result.rssi)
    }

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
                }
            }
        }
    }

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

    companion object {
        private const val TAG = "BLEProximityMonitor"
        const val MANUFACTURER_ID = 0xFFFF
        val MAGIC = byteArrayOf(0x43, 0x6E) // ASCII "Cn"
        const val RSSI_THRESHOLD = -75
        const val CONFIRM_HIT_COUNT = 2
        const val LOSS_TIMEOUT_MS = 6_000L
        private const val STALE_CHECK_INTERVAL_MS = 1_000L
    }
}
