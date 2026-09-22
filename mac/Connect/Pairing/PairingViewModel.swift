import Foundation
import AppKit
import CryptoKit
import Combine

/// Drives the pairing UI state machine and bridges `TransportManager`'s
/// handshake callbacks into user-facing confirm/trust prompts.
final class PairingViewModel: ObservableObject {
    enum PairingState: Equatable {
        case idle
        case showingQR
        case waitingForPhone
        case confirmingTrust(deviceName: String)
        case paired(deviceName: String)
        case failed(String)
    }

    @Published private(set) var state: PairingState = .idle
    @Published private(set) var qrImage: NSImage?

    private var currentPayload: PairingQRPayload?
    private weak var transportManager: TransportManager?
    private let trustedDevices: TrustedDevicesStore

    /// Set while `state == .confirmingTrust`; calling it answers the pending handshake.
    private var pendingConfirmation: ((Bool) -> Void)?

    init(transportManager: TransportManager, trustedDevices: TrustedDevicesStore = .shared) {
        self.transportManager = transportManager
        self.trustedDevices = trustedDevices
        wireTransport()
    }

    private func wireTransport() {
        transportManager?.onUntrustedHandshake = { [weak self] peer, _, confirm in
            guard let self else { confirm(false); return }
            DispatchQueue.main.async {
                self.pendingConfirmation = confirm
                self.state = .confirmingTrust(deviceName: peer.deviceName)
            }
        }
        transportManager?.onTrustedConnected = { [weak self] peer in
            DispatchQueue.main.async {
                self?.state = .paired(deviceName: peer.deviceName)
            }
        }
    }

    // MARK: - User-driven actions

    /// Begins a pairing attempt: generates a fresh pairing token + QR code and
    /// waits for the phone to scan it and dial in.
    func startPairing() {
        let payload = QRCodeGenerator.makePairingPayload()
        currentPayload = payload
        qrImage = QRCodeGenerator.image(for: payload)
        state = .showingQR
        transportManager?.start()
        // Once the phone connects, TransportManager will move through
        // .handshaking to either onUntrustedHandshake or onTrustedConnected.
        state = .waitingForPhone
    }

    /// User taps "Confirm" in response to `.confirmingTrust`.
    func confirmTrust() {
        pendingConfirmation?(true)
        pendingConfirmation = nil
    }

    /// User taps "Reject" in response to `.confirmingTrust`.
    func rejectTrust() {
        pendingConfirmation?(false)
        pendingConfirmation = nil
        state = .failed("Pairing rejected")
    }

    func reset() {
        currentPayload = nil
        qrImage = nil
        pendingConfirmation = nil
        state = .idle
    }
}
