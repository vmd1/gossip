package com.connect.features.hotspot

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.util.Log
import com.connect.crypto.IdentityKeyStore
import com.connect.crypto.TrustedDevicesStore
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import java.util.ArrayDeque
import kotlin.coroutines.resume

private const val TAG = "HotspotGattClient"

/**
 * The GATT *central* (client) side of Instant Hotspot's control channel — used by a
 * requesting Mac/tablet (from their normal continuous-scan role) or a requesting phone
 * (from [com.connect.features.proximity.BLEProximityMonitor.startHotspotRequestScan]'s
 * on-demand role); see `docs/ble-hotspot-protocol.md`'s "GATT roles". Only ever connects
 * to a `providerId` the caller has already confirmed both trusted and nearby.
 */
class HotspotGattClient(
    private val context: Context,
    private val identityKeyStore: IdentityKeyStore,
    private val trustedDevicesStore: TrustedDevicesStore
) {
    sealed class Result {
        data class Success(val enabled: Boolean, val ssid: String?, val passphrase: String?) : Result()
        data class Failed(val reason: String) : Result()
    }

    /** Connects to [device] (already known, via BLE proximity scanning, to be
     *  [providerId]), sends a signed `hotspot.toggle_request`, and waits for a verified,
     *  decrypted `hotspot.status` response — or [Result.Failed] on timeout, an untrusted
     *  provider, a bad signature, or a GATT-level failure. Suspends until settled;
     *  callers own their own UI-level cancellation. */
    @SuppressLint("MissingPermission")
    suspend fun requestToggle(
        device: BluetoothDevice,
        providerId: String,
        enable: Boolean,
        timeoutMs: Long = 15_000
    ): Result {
        val provider = trustedDevicesStore.getDevice(providerId)
        val signingKey = provider?.signingPublicKey
        if (provider == null || signingKey == null) {
            return Result.Failed("Provider not trusted or missing a signing key (may need to re-pair)")
        }
        val sharedSecretKey = HotspotGattProtocol.deriveSharedSecretKey(identityKeyStore.x25519KeyPair.privateKey, provider.publicKey)

        val outcome = withTimeoutOrNull(timeoutMs) {
            suspendCancellableCoroutine { continuation ->
                var settled = false
                fun settle(result: Result) {
                    if (settled) return
                    settled = true
                    if (continuation.isActive) continuation.resume(result)
                }

                val reassembler = HotspotGattProtocol.ChunkReassembler()
                val outboundQueue = ArrayDeque<ByteArray>()
                var sendInFlight = false
                var gatt: BluetoothGatt? = null
                var pendingRequestCharacteristic: BluetoothGattCharacteristic? = null

                fun drainOutbound(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
                    if (sendInFlight) return
                    val chunk = outboundQueue.poll() ?: return
                    sendInFlight = true
                    characteristic.value = chunk
                    @Suppress("DEPRECATION")
                    g.writeCharacteristic(characteristic)
                }

                val callback = object : BluetoothGattCallback() {
                    override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
                        if (newState == BluetoothProfile.STATE_CONNECTED) {
                            g.discoverServices()
                        } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                            settle(Result.Failed("Disconnected before a response was received (status=$status)"))
                            g.close()
                        }
                    }

                    override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
                        if (status != BluetoothGatt.GATT_SUCCESS) {
                            settle(Result.Failed("Service discovery failed: $status"))
                            g.close()
                            return
                        }
                        val service = g.getService(HotspotGattProtocol.SERVICE_UUID)
                        val responseChar = service?.getCharacteristic(HotspotGattProtocol.RESPONSE_CHARACTERISTIC_UUID)
                        val requestChar = service?.getCharacteristic(HotspotGattProtocol.REQUEST_CHARACTERISTIC_UUID)
                        if (service == null || responseChar == null || requestChar == null) {
                            settle(Result.Failed("Hotspot GATT service not found on this device"))
                            g.close()
                            return
                        }
                        // Deliberately does NOT send the request yet — see
                        // onDescriptorWrite below. Live-confirmed real bug on the Mac
                        // client (same race applies here): writing the request
                        // immediately after calling setCharacteristicNotification/
                        // writeDescriptor, without waiting for the CCCD write to
                        // actually complete, means a fast-responding peripheral's
                        // notifications can arrive before the subscription has taken
                        // effect and be silently dropped — the toggle happens
                        // server-side, but the client times out having received
                        // nothing.
                        pendingRequestCharacteristic = requestChar
                        g.setCharacteristicNotification(responseChar, true)
                        val cccd = responseChar.getDescriptor(HotspotGattProtocol.CCCD_UUID)
                        if (cccd == null) {
                            settle(Result.Failed("Response characteristic has no CCCD descriptor"))
                            g.close()
                            return
                        }
                        @Suppress("DEPRECATION")
                        cccd.value = BluetoothGattDescriptorEnableNotificationValue
                        @Suppress("DEPRECATION")
                        g.writeDescriptor(cccd)
                    }

                    override fun onDescriptorWrite(g: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
                        if (descriptor.uuid != HotspotGattProtocol.CCCD_UUID) return
                        if (status != BluetoothGatt.GATT_SUCCESS) {
                            settle(Result.Failed("Could not subscribe to hotspot status notifications: status=$status"))
                            g.close()
                            return
                        }
                        val requestChar = pendingRequestCharacteristic ?: return
                        val request = HotspotGattProtocol.ToggleRequestPayload.create(
                            requesterId = identityKeyStore.deviceId,
                            enable = enable,
                            privateKeySeed = identityKeyStore.ed25519PrivateKey
                        )
                        outboundQueue.addAll(HotspotGattProtocol.encodeChunks(HotspotGattProtocol.encodeRequest(request)))
                        drainOutbound(g, requestChar)
                    }

                    override fun onCharacteristicWrite(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
                        sendInFlight = false
                        if (status != BluetoothGatt.GATT_SUCCESS) {
                            settle(Result.Failed("Write failed: $status"))
                            g.close()
                            return
                        }
                        drainOutbound(g, characteristic)
                    }

                    @Suppress("DEPRECATION")
                    override fun onCharacteristicChanged(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
                        if (characteristic.uuid != HotspotGattProtocol.RESPONSE_CHARACTERISTIC_UUID) return
                        val complete = reassembler.feed(characteristic.value) ?: return
                        val status = HotspotGattProtocol.decodeStatus(complete)
                        if (status == null || !status.isSignatureValid(signingKey)) {
                            settle(Result.Failed("Malformed or unverifiable hotspot.status response"))
                            g.close()
                            return
                        }
                        val decrypted = status.decryptCredentials(sharedSecretKey)
                        settle(Result.Success(status.ok, decrypted?.first, decrypted?.second))
                        g.close()
                    }
                }

                gatt = device.connectGatt(context, false, callback)
                continuation.invokeOnCancellation { gatt?.close() }
            }
        }
        return outcome ?: Result.Failed("Timed out waiting for a response").also {
            Log.w(TAG, "hotspot.toggle_request to $providerId timed out")
        }
    }
}

/** `[0x01, 0x00]` — `BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE`, inlined so this
 *  file doesn't need a `@SuppressLint` on the constant reference itself (the constant is
 *  fine to use directly; only the deprecated `writeDescriptor(BluetoothGattDescriptor)`
 *  overload above needs the suppression). */
private val BluetoothGattDescriptorEnableNotificationValue = byteArrayOf(0x01, 0x00)
