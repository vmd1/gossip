package dev.vmd1.gossip.features.hotspot

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.content.Context
import android.util.Log
import dev.vmd1.gossip.crypto.IdentityKeyStore
import dev.vmd1.gossip.crypto.TrustedDevicesStore
import dev.vmd1.gossip.onboarding.OnboardingPreferences
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import java.util.concurrent.ConcurrentHashMap

private const val TAG = "HotspotGattServer"

/**
 * The GATT *peripheral* (server) side of Instant Hotspot's control channel — phone-only,
 * per `docs/ble-hotspot-protocol.md`'s "GATT roles" (a phone is always the server; the
 * client role is generic over requester device type). Started unconditionally alongside
 * [dev.vmd1.gossip.features.proximity.BLEProximityMonitor]'s advertising (cheap to have
 * registered; the *capability bit* in the advertisement, not this server's presence, is
 * what a requester actually checks first — see that class), but every request is
 * re-checked against [OnboardingPreferences.provideHotspotEnabled] at request time too
 * (defense in depth: a requester that connects despite the capability bit being off,
 * e.g. a stale scan result, still gets refused here, never silently ignored).
 *
 * Idempotent by construction, per this project's `CLAUDE.md` convention: applying the
 * same `hotspot.toggle_request` twice is a no-op the second time because the underlying
 * OS toggle (`TetherHelper.setHotspotEnabled`) is itself idempotent — turning on an
 * already-on hotspot succeeds trivially — so no separate dedupe/idempotency-key cache is
 * needed here, unlike `notification.reply`'s real side-effect-outside-the-app problem.
 */
class HotspotGattServer(
    private val context: Context,
    private val identityKeyStore: IdentityKeyStore,
    private val trustedDevicesStore: TrustedDevicesStore,
    private val scope: CoroutineScope,
    private val shizukuManager: ShizukuManager? = null
) {
    private var gattServer: BluetoothGattServer? = null
    private val reassemblers = ConcurrentHashMap<String, HotspotGattProtocol.ChunkReassembler>()

    /** Per-device outbound chunk queue. Firing `notifyCharacteristicChanged` back-to-back
     *  without waiting for the previous chunk's `onNotificationSent` is a known way to
     *  silently drop notifications on Android's BLE stack (only one GATT operation may be
     *  in flight per connection at a time) — this queue serializes sends per device so
     *  every chunk actually goes out, at the cost of one extra round-trip of latency per
     *  chunk, acceptable for this feature's small, occasional payloads. */
    private val pendingChunks = ConcurrentHashMap<String, ArrayDeque<ByteArray>>()
    private val sendInFlight = ConcurrentHashMap<String, Boolean>()

    @SuppressLint("MissingPermission")
    fun start() {
        try {
            val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
            if (manager == null) {
                Log.w(TAG, "start(): no BluetoothManager available")
                return
            }
            val server = manager.openGattServer(context, callback)
            if (server == null) {
                Log.w(TAG, "openGattServer returned null; hotspot GATT server not started")
                return
            }
            gattServer = server

            val requestCharacteristic = BluetoothGattCharacteristic(
                HotspotGattProtocol.REQUEST_CHARACTERISTIC_UUID,
                BluetoothGattCharacteristic.PROPERTY_WRITE,
                BluetoothGattCharacteristic.PERMISSION_WRITE
            )
            val responseCharacteristic = BluetoothGattCharacteristic(
                HotspotGattProtocol.RESPONSE_CHARACTERISTIC_UUID,
                BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                BluetoothGattCharacteristic.PERMISSION_READ
            )
            val cccd = BluetoothGattDescriptor(
                HotspotGattProtocol.CCCD_UUID,
                BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE
            )
            responseCharacteristic.addDescriptor(cccd)

            val service = BluetoothGattService(HotspotGattProtocol.SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
            service.addCharacteristic(requestCharacteristic)
            service.addCharacteristic(responseCharacteristic)
            server.addService(service)
        } catch (e: Exception) {
            // GATT server setup touches several OS-level BLE calls in sequence
            // (registerCallback, addService) that can throw for reasons outside this
            // app's control (radio state, permission edge cases) — caught and logged
            // rather than left to crash the whole foreground service over a feature
            // that should degrade gracefully instead.
            Log.e(TAG, "start() failed", e)
        }
    }

    @SuppressLint("MissingPermission")
    fun stop() {
        gattServer?.close()
        gattServer = null
        reassemblers.clear()
    }

    private val callback = object : BluetoothGattServerCallback() {
        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray
        ) {
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null)
            }
            if (characteristic.uuid != HotspotGattProtocol.REQUEST_CHARACTERISTIC_UUID) return

            val reassembler = reassemblers.getOrPut(device.address) { HotspotGattProtocol.ChunkReassembler() }
            val complete = reassembler.feed(value) ?: return
            val request = HotspotGattProtocol.decodeRequest(complete)
            if (request == null) {
                Log.w(TAG, "Malformed hotspot.toggle_request from ${device.address}")
                return
            }
            handleRequest(device, request)
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray
        ) {
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null)
            }
        }

        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (newState == BluetoothGatt.STATE_DISCONNECTED) {
                reassemblers.remove(device.address)
                pendingChunks.remove(device.address)
                sendInFlight.remove(device.address)
            }
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            sendInFlight[device.address] = false
            drainQueue(device)
        }
    }

    @SuppressLint("MissingPermission")
    private fun drainQueue(device: BluetoothDevice) {
        if (sendInFlight[device.address] == true) return
        val queue = pendingChunks[device.address] ?: return
        val chunk = queue.removeFirstOrNull() ?: return
        val server = gattServer ?: return
        val service = server.getService(HotspotGattProtocol.SERVICE_UUID) ?: return
        val characteristic = service.getCharacteristic(HotspotGattProtocol.RESPONSE_CHARACTERISTIC_UUID) ?: return
        characteristic.value = chunk
        sendInFlight[device.address] = true
        @Suppress("DEPRECATION")
        server.notifyCharacteristicChanged(device, characteristic, false)
    }

    private fun handleRequest(device: BluetoothDevice, request: HotspotGattProtocol.ToggleRequestPayload) {
        scope.launch {
            val requester = trustedDevicesStore.getDevice(request.id)
            val signingKey = requester?.signingPublicKey
            if (requester == null || signingKey == null || !request.isSignatureValid(signingKey)) {
                Log.w(TAG, "Rejecting hotspot.toggle_request from untrusted/unverifiable sender ${request.id}")
                return@launch
            }
            // Same X25519 identity key already used for Noise_IK (`TrustedDevice.publicKey`)
            // — see HotspotGattProtocol.deriveSharedSecretKey's doc comment for why reusing
            // it here, with domain separation, is safe.
            val sharedSecretKey = HotspotGattProtocol.deriveSharedSecretKey(
                identityKeyStore.x25519KeyPair.privateKey,
                requester.publicKey
            )

            val prefs = OnboardingPreferences(context)
            if (!dev.vmd1.gossip.features.settings.FeatureSettings.getInstance(context)
                    .isEnabled(dev.vmd1.gossip.features.settings.Feature.HOTSPOT)
            ) {
                Log.i(TAG, "Rejecting hotspot.toggle_request: the Instant Hotspot feature is turned off")
                sendResponse(device, request, enabled = false, sharedSecretKey = sharedSecretKey)
                return@launch
            }
            if (!prefs.provideHotspotEnabled) {
                Log.i(TAG, "Rejecting hotspot.toggle_request: 'Provide Instant Hotspot' is off")
                sendResponse(device, request, enabled = false, sharedSecretKey = sharedSecretKey)
                return@launch
            }

            val result = TetherHelper.setHotspotEnabled(
                context = context,
                enable = request.en,
                shizukuManager = shizukuManager,
                preferredMechanismId = prefs.preferredHotspotMechanismId
            )
            // The *resulting* hotspot state, not just "did the requested operation
            // succeed" — a successful stop must report enabled=false, not true. Real
            // bug, confirmed live: the `sendResponse` call below used to pass
            // `result == SUCCESS` directly, which is true for *any* successful
            // operation regardless of direction — so a successful stop reported
            // enabled=true, and the requester's UI said "that device kept its hotspot
            // on" immediately after it had genuinely just been turned off.
            val enabled = result == TetherHelper.ToggleResult.SUCCESS && request.en
            val credentials = if (enabled) HotspotCredentialReader.readCredentials(context, shizukuManager) else null
            sendResponse(
                device,
                request,
                enabled = enabled,
                sharedSecretKey = sharedSecretKey,
                credentials = credentials
            )
        }
    }

    private fun sendResponse(
        device: BluetoothDevice,
        request: HotspotGattProtocol.ToggleRequestPayload,
        enabled: Boolean,
        sharedSecretKey: ByteArray,
        credentials: HotspotCredentialReader.Credentials? = null
    ) {
        val status = HotspotGattProtocol.StatusPayload.create(
            providerId = identityKeyStore.deviceId,
            enabled = enabled,
            nonce = request.n,
            privateKeySeed = identityKeyStore.ed25519PrivateKey,
            sharedSecretKey = sharedSecretKey,
            ssid = credentials?.ssid,
            passphrase = credentials?.passphrase
        )
        val chunks = HotspotGattProtocol.encodeChunks(HotspotGattProtocol.encodeStatus(status))
        pendingChunks.getOrPut(device.address) { ArrayDeque() }.addAll(chunks)
        drainQueue(device)
    }
}
