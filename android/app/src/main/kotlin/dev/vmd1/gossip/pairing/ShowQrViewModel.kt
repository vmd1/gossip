package dev.vmd1.gossip.pairing

import android.util.Base64
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import dev.vmd1.gossip.crypto.IdentityKeyStore
import dev.vmd1.gossip.protocol.DeviceType
import dev.vmd1.gossip.transport.HandshakePeerInfo
import dev.vmd1.gossip.transport.TransportManager
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import java.util.UUID

sealed class ShowQrUiState {
    data object Idle : ShowQrUiState()
    data class ShowingQr(val payload: PairingQrPayload) : ShowQrUiState()
    data class ConfirmingTrust(val deviceName: String, val code: String) : ShowQrUiState()
    data class Success(val deviceName: String) : ShowQrUiState()
    data class Failed(val reason: String) : ShowQrUiState()
}

/**
 * Drives the *responder* side of pairing: this device shows a QR (`startShowingQr`)
 * carrying its own identity + static public key, another device scans it and dials in
 * as the Noise_IK initiator, and — since that peer isn't trusted yet —
 * [TransportManager.onUntrustedHandshake] fires here to prompt the user to confirm
 * before it's added to `TrustedDevicesStore`. Mirrors Mac's `PairingViewModel`, which
 * has always played this same responder role (Mac being the only platform that could
 * show a QR before mesh support).
 *
 * `onUntrustedHandshake` is only armed while this ViewModel is alive (wired in [init],
 * cleared in [onCleared]) — i.e. only while the user has this screen open — so a device
 * sitting in a pocket/bag never prompts to trust a stranger just because
 * [TransportManager] is always listening in the background.
 */
class ShowQrViewModel(
    private val transportManager: TransportManager,
    private val identityKeyStore: IdentityKeyStore,
    private val deviceName: String,
    private val deviceType: DeviceType
) : ViewModel() {

    private val _uiState = MutableStateFlow<ShowQrUiState>(ShowQrUiState.Idle)
    val uiState: StateFlow<ShowQrUiState> = _uiState.asStateFlow()

    private var pendingConfirmation: CompletableDeferred<Boolean>? = null

    init {
        transportManager.onUntrustedHandshake = { peer, publicKey -> handleUntrustedHandshake(peer, publicKey) }
    }

    fun startShowingQr() {
        val payload = PairingQrPayload(
            responderDeviceId = identityKeyStore.deviceId,
            responderPublicKey = Base64.encodeToString(identityKeyStore.x25519KeyPair.publicKey, Base64.NO_WRAP),
            responderPublicKeyFingerprint = identityKeyStore.publicKeyFingerprint(),
            responderDeviceName = deviceName,
            responderDeviceType = deviceType.wireValue,
            pairingToken = UUID.randomUUID().toString(),
            responderSigningPublicKey = Base64.encodeToString(identityKeyStore.ed25519PublicKey, Base64.NO_WRAP)
        )
        transportManager.armPairing(payload.pairingToken)
        _uiState.value = ShowQrUiState.ShowingQr(payload)
    }

    /** User tapped "Confirm" in response to [ShowQrUiState.ConfirmingTrust]. */
    fun confirmTrust() {
        pendingConfirmation?.complete(true)
        pendingConfirmation = null
    }

    /** User tapped "Reject" in response to [ShowQrUiState.ConfirmingTrust]. */
    fun rejectTrust() {
        pendingConfirmation?.complete(false)
        pendingConfirmation = null
        failWith("Pairing rejected")
    }

    fun reset() {
        transportManager.disarmPairing()
        failureClearJob?.cancel()
        _uiState.value = ShowQrUiState.Idle
    }

    private var failureClearJob: kotlinx.coroutines.Job? = null

    /** Shows a failure, then goes back to showing the QR by itself after [ERROR_LIFETIME_MS] (what
     *  "Try again" does) so a stale error never lingers. */
    private fun failWith(reason: String) {
        val failed = ShowQrUiState.Failed(reason)
        _uiState.value = failed
        failureClearJob?.cancel()
        failureClearJob = viewModelScope.launch {
            kotlinx.coroutines.delay(ERROR_LIFETIME_MS)
            if (_uiState.value === failed) startShowingQr()
        }
    }

    /** Called from [TransportManager]'s own connection-handling coroutine — suspends
     *  (blocking that one connection's handshake, not the rest of the app) until the
     *  user answers via [confirmTrust]/[rejectTrust]. */
    private suspend fun handleUntrustedHandshake(peer: HandshakePeerInfo, publicKey: ByteArray): Boolean {
        val deferred = CompletableDeferred<Boolean>()
        pendingConfirmation = deferred
        _uiState.value = ShowQrUiState.ConfirmingTrust(peer.deviceName, transportManager.pairingCodeFor(publicKey))
        val confirmed = deferred.await()
        if (confirmed) {
            viewModelScope.launch {
                val connected = withTimeoutOrNull(HANDSHAKE_TIMEOUT_MS) {
                    transportManager.connectedDeviceIds.first { it.contains(peer.deviceId) }
                }
                if (connected != null) {
                    _uiState.value = ShowQrUiState.Success(peer.deviceName)
                } else {
                    failWith("Connection did not complete")
                }
            }
        }
        return confirmed
    }

    override fun onCleared() {
        super.onCleared()
        // Only clear if we're still the ones armed — a second ShowQrViewModel instance
        // (e.g. screen recreated) may have already replaced us.
        pendingConfirmation?.complete(false)
        pendingConfirmation = null
        transportManager.disarmPairing()
    }

    companion object {
        private const val HANDSHAKE_TIMEOUT_MS = 15_000L
        private const val ERROR_LIFETIME_MS = 10_000L
    }
}

class ShowQrViewModelFactory(
    private val transportManager: TransportManager,
    private val identityKeyStore: IdentityKeyStore,
    private val deviceName: String,
    private val deviceType: DeviceType
) : ViewModelProvider.Factory {
    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T {
        require(modelClass.isAssignableFrom(ShowQrViewModel::class.java))
        return ShowQrViewModel(transportManager, identityKeyStore, deviceName, deviceType) as T
    }
}
