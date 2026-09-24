package com.connect.pairing

import android.util.Base64
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.connect.crypto.TrustedDevice
import com.connect.crypto.TrustedDevicesStore
import com.connect.features.trust.RosterGossipManager
import com.connect.protocol.DeviceType
import com.connect.transport.DiscoveredPeer
import com.connect.transport.DiscoveryEvent
import com.connect.transport.TransportManager
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** The payload encoded in the QR code shown by whichever device is the pairing
 *  responder — originally always the Mac, but since mesh support either platform can
 *  show one (see [com.connect.pairing.ShowQrViewModel]) — generic field names rather
 *  than `mac*`; not part of the wire envelope (`schema/message-types.md`), both
 *  platforms' generator/scanner just need to agree on this shape. */
@Serializable
data class PairingQrPayload(
    val responderDeviceId: String,
    /** Base64 X25519 static public key — required to run Noise_IK as the initiator. */
    val responderPublicKey: String,
    val responderPublicKeyFingerprint: String,
    val responderDeviceName: String,
    val responderDeviceType: String,
    val pairingToken: String
)

sealed class PairingUiState {
    data object Idle : PairingUiState()
    data object Discovering : PairingUiState()
    data object Handshaking : PairingUiState()
    data class Success(val deviceId: String, val deviceName: String) : PairingUiState()
    data class Failed(val reason: String) : PairingUiState()
}

/**
 * Drives the pairing UI state machine: parse the scanned QR, resolve the Mac on the
 * local network via NSD, connect + run the Noise_IK handshake through
 * [TransportManager], and on success add the peer to [TrustedDevicesStore]. Mirrors
 * the state machine the Mac side of pairing runs through the same steps in reverse
 * (advertise -> accept -> handshake -> trust).
 */
class PairingViewModel(
    private val transportManager: TransportManager,
    private val trustedDevicesStore: TrustedDevicesStore,
    private val rosterGossipManager: RosterGossipManager? = null
) : ViewModel() {

    private val _uiState = MutableStateFlow<PairingUiState>(PairingUiState.Idle)
    val uiState: StateFlow<PairingUiState> = _uiState.asStateFlow()

    fun onQrScanned(rawValue: String) {
        val payload = try {
            Json { ignoreUnknownKeys = true }.decodeFromString(PairingQrPayload.serializer(), rawValue)
        } catch (e: Exception) {
            _uiState.value = PairingUiState.Failed("Unreadable QR code: ${e.message}")
            return
        }

        viewModelScope.launch {
            _uiState.value = PairingUiState.Discovering
            val peer = withTimeoutOrNull(DISCOVERY_TIMEOUT_MS) {
                findPeer(payload.responderDeviceId)
            }
            if (peer == null || peer.host == null) {
                _uiState.value = PairingUiState.Failed("Could not find ${payload.responderDeviceId} on the local network")
                return@launch
            }

            _uiState.value = PairingUiState.Handshaking
            val remoteStaticKey = Base64.decode(payload.responderPublicKey, Base64.NO_WRAP)
            transportManager.connect(peer.host, peer.port, remoteStaticKey, deviceId = payload.responderDeviceId)

            // Wait for *this specific* device to show up as connected, not just "connected
            // to anything" — with a mesh, this device may already be connected to some
            // other trusted device, which would otherwise make a plain CONNECTED check
            // resolve immediately without actually waiting for this handshake to finish.
            val connected = withTimeoutOrNull(HANDSHAKE_TIMEOUT_MS) {
                waitForDeviceConnected(payload.responderDeviceId)
            } ?: false

            if (connected) {
                trustedDevicesStore.addDevice(
                    TrustedDevice(
                        deviceId = payload.responderDeviceId,
                        publicKey = remoteStaticKey,
                        deviceName = payload.responderDeviceName,
                        deviceType = DeviceType.fromWire(payload.responderDeviceType),
                        addedAt = System.currentTimeMillis()
                    )
                )
                // Brand-new pairing (not a reconnect to an already-trusted device) —
                // broadcast the updated roster so the rest of the mesh learns about
                // this new device without waiting for the periodic resync.
                rosterGossipManager?.announceNewDevice()
                _uiState.value = PairingUiState.Success(payload.responderDeviceId, payload.responderDeviceName)
            } else {
                _uiState.value = PairingUiState.Failed("Handshake did not complete")
            }
        }
    }

    fun reset() {
        _uiState.value = PairingUiState.Idle
    }

    private suspend fun findPeer(responderDeviceId: String): DiscoveredPeer? {
        var found: DiscoveredPeer? = null
        transportManager.discovery.discover().let { flow ->
            flow.first { event ->
                if (event is DiscoveryEvent.Found && event.peer.deviceId == responderDeviceId) {
                    found = event.peer
                    true
                } else {
                    false
                }
            }
        }
        return found
    }

    private suspend fun waitForDeviceConnected(deviceId: String): Boolean =
        transportManager.connectedDeviceIds.first { it.contains(deviceId) }.let { true }

    companion object {
        private const val DISCOVERY_TIMEOUT_MS = 15_000L
        private const val HANDSHAKE_TIMEOUT_MS = 15_000L
    }
}

class PairingViewModelFactory(
    private val transportManager: TransportManager,
    private val trustedDevicesStore: TrustedDevicesStore,
    private val rosterGossipManager: RosterGossipManager? = null
) : ViewModelProvider.Factory {
    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T {
        require(modelClass.isAssignableFrom(PairingViewModel::class.java))
        return PairingViewModel(transportManager, trustedDevicesStore, rosterGossipManager) as T
    }
}
