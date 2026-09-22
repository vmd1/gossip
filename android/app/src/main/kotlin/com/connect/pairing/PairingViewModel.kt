package com.connect.pairing

import android.util.Base64
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.connect.crypto.TrustedDevice
import com.connect.crypto.TrustedDevicesStore
import com.connect.protocol.DeviceType
import com.connect.transport.ConnectionState
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

/** The payload encoded in the QR code the Mac app renders during pairing. */
@Serializable
data class PairingQrPayload(
    val macDeviceId: String,
    /** Base64 X25519 static public key — required to run Noise_IK as the initiator. */
    val macPublicKey: String,
    val macPublicKeyFingerprint: String,
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
    private val trustedDevicesStore: TrustedDevicesStore
) : ViewModel() {

    private val _uiState = MutableStateFlow<PairingUiState>(PairingUiState.Idle)
    val uiState: StateFlow<PairingUiState> = _uiState.asStateFlow()

    private var pendingDeviceName: String = "Mac"

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
                findPeer(payload.macDeviceId)
            }
            if (peer == null || peer.host == null) {
                _uiState.value = PairingUiState.Failed("Could not find ${payload.macDeviceId} on the local network")
                return@launch
            }

            _uiState.value = PairingUiState.Handshaking
            val remoteStaticKey = Base64.decode(payload.macPublicKey, Base64.NO_WRAP)
            transportManager.connect(peer.host, peer.port, remoteStaticKey)

            val finalState = withTimeoutOrNull(HANDSHAKE_TIMEOUT_MS) {
                waitForConnectedOrDisconnected()
            }

            when (finalState) {
                ConnectionState.CONNECTED -> {
                    val deviceId = transportManager.currentRemoteDeviceId() ?: payload.macDeviceId
                    trustedDevicesStore.addDevice(
                        TrustedDevice(
                            deviceId = deviceId,
                            publicKey = remoteStaticKey,
                            deviceName = pendingDeviceName,
                            deviceType = DeviceType.MAC,
                            addedAt = System.currentTimeMillis()
                        )
                    )
                    _uiState.value = PairingUiState.Success(deviceId, pendingDeviceName)
                }
                else -> _uiState.value = PairingUiState.Failed("Handshake did not complete")
            }
        }
    }

    fun reset() {
        _uiState.value = PairingUiState.Idle
    }

    private suspend fun findPeer(macDeviceId: String): DiscoveredPeer? {
        var found: DiscoveredPeer? = null
        transportManager.discovery.discover().let { flow ->
            flow.first { event ->
                if (event is DiscoveryEvent.Found && event.peer.deviceId == macDeviceId) {
                    found = event.peer
                    true
                } else {
                    false
                }
            }
        }
        return found
    }

    private suspend fun waitForConnectedOrDisconnected(): ConnectionState =
        transportManager.connectionState.first { it == ConnectionState.CONNECTED }

    companion object {
        private const val DISCOVERY_TIMEOUT_MS = 15_000L
        private const val HANDSHAKE_TIMEOUT_MS = 15_000L
    }
}

class PairingViewModelFactory(
    private val transportManager: TransportManager,
    private val trustedDevicesStore: TrustedDevicesStore
) : ViewModelProvider.Factory {
    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T {
        require(modelClass.isAssignableFrom(PairingViewModel::class.java))
        return PairingViewModel(transportManager, trustedDevicesStore) as T
    }
}
