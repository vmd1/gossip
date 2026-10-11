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
        /// This is the new device: `code` is what the user types into a device that is already paired.
        case showingCode(code: String, attemptsLeft: Int?)
        /// This device is already paired: the user types the code the new device shows.
        case enteringCode
        /// A code was typed here; looking for the device showing it.
        case searching
        case confirmingTrust(deviceName: String, code: String)
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
        transportManager?.onUntrustedHandshake = { [weak self] peer, publicKey, confirm in
            guard let self else { confirm(false); return }
            let code = PairingCode.make(IdentityKeyStore.shared.agreementKey.publicKey.rawRepresentation, publicKey.rawRepresentation)
            DispatchQueue.main.async {
                // One prompt at a time: a second one never replaces (and so never hijacks) the first.
                guard self.pendingConfirmation == nil else { confirm(false); return }
                self.pendingConfirmation = confirm
                self.state = .confirmingTrust(deviceName: peer.deviceName, code: code)
            }
        }
        transportManager?.onUntrustedPromptCancelled = { [weak self] in
            guard let self, self.pendingConfirmation != nil else { return }
            self.pendingConfirmation = nil
            self.state = .failed("The other device disconnected before pairing finished")
        }
        transportManager?.onCodePairingEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .succeeded(let peer):
                self.state = .paired(deviceName: peer.deviceName)
                NotificationCenter.default.post(name: .gossipDevicePaired, object: nil)
            case .wrongCode(let left):
                if case .showingCode(let code, _) = self.state { self.state = .showingCode(code: code, attemptsLeft: left) }
            case .tooManyAttempts:
                self.state = .failed("Too many wrong codes. Start again to get a new code.")
            case .expired:
                self.state = .failed("The code expired. Start again to get a new one.")
            case .rejected:
                self.state = .failed("That code didn't work. Check it against the other device and try again.")
            case .noDeviceFound:
                self.state = .failed("No device on this network is showing a code. Open the pairing code screen on the new device first.")
            }
        }
        transportManager?.addOnTrustedConnected { [weak self] peer in
            DispatchQueue.main.async {
                // Every reconnect of a trusted device lands here too; only a pairing that is actually in progress counts.
                guard let self, self.state != .idle else { return }
                self.pendingConfirmation = nil
                self.state = .paired(deviceName: peer.deviceName)
                NotificationCenter.default.post(name: .gossipDevicePaired, object: nil)
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
        transportManager?.armPairing(token: payload.pairingToken)
        transportManager?.start()
        // Once the phone connects, TransportManager will move through
        // .handshaking to either onUntrustedHandshake or onTrustedConnected.
        state = .waitingForPhone
    }

    /// This Mac is the new device: shows a code to type into a device that is already paired.
    func showCode() {
        transportManager?.disarmPairing()
        qrImage = nil
        transportManager?.start()
        guard let code = transportManager?.startCodePairing() else { return }
        state = .showingCode(code: code, attemptsLeft: nil)
    }

    /// This Mac is already paired: lets the user type the code the new device shows.
    func beginEnteringCode() {
        transportManager?.disarmPairing()
        qrImage = nil
        transportManager?.start()
        state = .enteringCode
    }

    func submitCode(_ text: String) {
        state = .searching
        transportManager?.enterCode(text)
    }

    /// User taps "Confirm" in response to `.confirmingTrust`.
    func confirmTrust() {
        pendingConfirmation?(true)
        pendingConfirmation = nil
        transportManager?.disarmPairing()
    }

    /// User taps "Reject" in response to `.confirmingTrust`.
    func rejectTrust() {
        pendingConfirmation?(false)
        pendingConfirmation = nil
        transportManager?.disarmPairing()
        state = .failed("Pairing rejected")
    }

    func reset() {
        transportManager?.stopCodePairing()
        transportManager?.disarmPairing()
        currentPayload = nil
        qrImage = nil
        // Answer an open prompt (as a rejection) so the transport releases its single prompt slot.
        pendingConfirmation?(false)
        pendingConfirmation = nil
        state = .idle
    }
}

extension Notification.Name {
    /// Posted (main thread) when a pairing the user started finished; onboarding uses it to move on by itself.
    static let gossipDevicePaired = Notification.Name("dev.vmd1.gossip.devicePaired")
}
