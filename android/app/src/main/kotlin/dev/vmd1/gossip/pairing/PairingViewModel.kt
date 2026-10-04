package dev.vmd1.gossip.pairing

import android.util.Base64
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import dev.vmd1.gossip.crypto.TrustedDevice
import dev.vmd1.gossip.crypto.TrustedDevicesStore
import dev.vmd1.gossip.features.trust.RosterGossipManager
import dev.vmd1.gossip.protocol.DeviceType
import dev.vmd1.gossip.transport.DiscoveredPeer
import dev.vmd1.gossip.transport.DiscoveryEvent
import dev.vmd1.gossip.transport.TransportManager
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
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
 *  show one (see [dev.vmd1.gossip.pairing.ShowQrViewModel]) — generic field names rather
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
    val pairingToken: String,
    /** Base64 Ed25519 signing public key — see `HandshakePayload.signingPublicKey`.
     *  Carried here too (not just over the handshake) because the *initiator* (the
     *  device scanning this QR) never receives a `HandshakePeerInfo` back from
     *  [dev.vmd1.gossip.transport.TransportManager.connect]; it only learns the
     *  responder's identity from this payload. */
    val responderSigningPublicKey: String
)

sealed class PairingUiState {
    data object Idle : PairingUiState()
    data object Discovering : PairingUiState()
    /** The QR was read; nothing is trusted or connected until the user confirms this [deviceName] / [code]. */
    data class ConfirmScan(val deviceName: String, val code: String) : PairingUiState()
    /** [code] is the short code the other device shows too, so the user can check both screens match. */
    data class Handshaking(val code: String) : PairingUiState()
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

    private var scanned: PairingQrPayload? = null

    /** Reads and validates the QR, then asks the user whether to pair — scanning alone is not consent, since a QR
     *  can be shown anywhere and the name in it is chosen by whoever made it. */
    fun onQrScanned(rawValue: String) {
        val payload = try {
            Json { ignoreUnknownKeys = true }.decodeFromString(PairingQrPayload.serializer(), rawValue)
        } catch (e: Exception) {
            failWith("Unreadable QR code")
            return
        }
        val key = RosterGossipManager.decodeKey(payload.responderPublicKey)
        if (!RosterGossipManager.isUuid(payload.responderDeviceId) || key == null ||
            RosterGossipManager.decodeKey(payload.responderSigningPublicKey) == null || payload.pairingToken.length > 64
        ) {
            failWith("Unreadable QR code")
            return
        }
        scanned = payload
        _uiState.value = PairingUiState.ConfirmScan(payload.responderDeviceName.take(80), transportManager.pairingCodeFor(key))
    }

    /** The user checked the name and code and agreed to pair. */
    fun confirmScan() {
        val payload = scanned ?: return
        scanned = null
        startPairing(payload)
    }

    fun cancelScan() {
        scanned = null
        _uiState.value = PairingUiState.Idle
    }

    private fun startPairing(payload: PairingQrPayload) {
        viewModelScope.launch {
            _uiState.value = PairingUiState.Discovering
            val peer = withTimeoutOrNull(DISCOVERY_TIMEOUT_MS) {
                findPeer(payload.responderDeviceId)
            }
            if (peer == null || peer.host == null) {
                failWith("Could not find ${payload.responderDeviceId} on the local network")
                return@launch
            }

            val remoteStaticKey = RosterGossipManager.decodeKey(payload.responderPublicKey)
            if (remoteStaticKey == null) { failWith("Unreadable QR code"); return@launch }
            _uiState.value = PairingUiState.Handshaking(transportManager.pairingCodeFor(remoteStaticKey))
            transportManager.connect(
                peer.host, peer.port, remoteStaticKey,
                deviceId = payload.responderDeviceId, pairingToken = payload.pairingToken
            )

            // The responder acks the handshake *before* its user confirms, so a plain
            // "connected" proves nothing about consent. Pairing only counts once the responder
            // sends its first message, which it does only after its user taps Confirm. The row is
            // added first (the QR carries the key and signing key) so that message verifies;
            // it is removed again if the responder never confirms.
            val rowAlreadyTrusted = trustedDevicesStore.isTrusted(payload.responderDeviceId)
            if (!rowAlreadyTrusted) {
                // Provisional rows are left out of roster gossip until the other side confirms.
                trustedDevicesStore.markProvisional(payload.responderDeviceId)
                trustedDevicesStore.addDevice(
                    TrustedDevice(
                        deviceId = payload.responderDeviceId,
                        publicKey = remoteStaticKey,
                        deviceName = payload.responderDeviceName,
                        deviceType = DeviceType.fromWire(payload.responderDeviceType),
                        addedAt = System.currentTimeMillis(),
                        signingPublicKey = RosterGossipManager.decodeKey(payload.responderSigningPublicKey)
                    )
                )
            }
            val firstMessage = async(start = CoroutineStart.UNDISPATCHED) {
                transportManager.incoming.first { it.senderId == payload.responderDeviceId }
            }
            transportManager.connect(
                peer.host, peer.port, remoteStaticKey,
                deviceId = payload.responderDeviceId, pairingToken = payload.pairingToken
            )
            val confirmed = withTimeoutOrNull(CONFIRM_TIMEOUT_MS) { firstMessage.await() } != null
            firstMessage.cancel()

            trustedDevicesStore.clearProvisional(payload.responderDeviceId)
            if (confirmed) {
                // Brand-new pairing (not a reconnect to an already-trusted device) —
                // broadcast the updated roster so the rest of the mesh learns about
                // this new device without waiting for the periodic resync.
                rosterGossipManager?.announceNewDevice()
                _uiState.value = PairingUiState.Success(payload.responderDeviceId, payload.responderDeviceName)
            } else {
                if (!rowAlreadyTrusted) trustedDevicesStore.remove(payload.responderDeviceId)
                transportManager.disconnect(payload.responderDeviceId)
                failWith("The other device did not confirm the pairing")
            }
        }
    }

    fun reset() {
        failureClearJob?.cancel()
        _uiState.value = PairingUiState.Idle
    }

    private var failureClearJob: kotlinx.coroutines.Job? = null

    /** Shows a failure, then returns to [PairingUiState.Idle] by itself after [ERROR_LIFETIME_MS]
     *  so a stale error never lingers (the scanner re-arms when it sees Idle). */
    private fun failWith(reason: String) {
        val failed = PairingUiState.Failed(reason)
        _uiState.value = failed
        failureClearJob?.cancel()
        failureClearJob = viewModelScope.launch {
            kotlinx.coroutines.delay(ERROR_LIFETIME_MS)
            if (_uiState.value === failed) _uiState.value = PairingUiState.Idle
        }
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

    companion object {
        private const val DISCOVERY_TIMEOUT_MS = 15_000L
        private const val CONFIRM_TIMEOUT_MS = 60_000L
        private const val ERROR_LIFETIME_MS = 10_000L
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
