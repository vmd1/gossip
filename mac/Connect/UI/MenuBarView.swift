import SwiftUI

struct MenuBarView: View {
    @ObservedObject var transportManager: TransportManager
    @ObservedObject var pairingViewModel: PairingViewModel
    @ObservedObject var trustedDevicesStore: TrustedDevicesStore

    @State private var showingPairingSheet = false
    @State private var showingDNDSetupSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusRow

            Divider()

            Button("Pair New Device…") {
                pairingViewModel.startPairing()
                showingPairingSheet = true
            }

            Button("Do Not Disturb Sync Setup…") {
                showingDNDSetupSheet = true
            }

            Divider()

            Text("Trusted Devices")
                .font(.headline)

            if trustedDevicesStore.devices.isEmpty {
                Text("No trusted devices yet.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(trustedDevicesStore.devices) { device in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(device.deviceName)
                            Text(device.deviceType.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Forget") {
                            trustedDevicesStore.revoke(deviceId: device.deviceId)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Divider()

            Button("Quit Connect") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 280)
        .sheet(isPresented: $showingPairingSheet) {
            PairingSheetView(pairingViewModel: pairingViewModel, isPresented: $showingPairingSheet)
        }
        .sheet(isPresented: $showingDNDSetupSheet) {
            DNDSetupView(isPresented: $showingDNDSetupSheet)
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.subheadline)
        }
    }

    private var statusColor: Color {
        switch transportManager.connectionState {
        case .disconnected: return .gray
        case .discovering: return .yellow
        case .handshaking: return .orange
        case .connected: return .green
        }
    }

    private var statusText: String {
        switch transportManager.connectionState {
        case .disconnected: return "Disconnected"
        case .discovering: return "Searching for devices…"
        case .handshaking: return "Connecting…"
        case .connected(let deviceId):
            let name = trustedDevicesStore.device(for: deviceId)?.deviceName ?? deviceId
            return "Connected to \(name)"
        }
    }
}

/// Minimal sheet shown while pairing a new device: displays the QR code and
/// reacts to handshake confirmation state. Unstyled by design — this
/// milestone is about the transport/crypto plumbing, not UI polish.
struct PairingSheetView: View {
    @ObservedObject var pairingViewModel: PairingViewModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 16) {
            switch pairingViewModel.state {
            case .idle:
                Text("Preparing…")
            case .showingQR, .waitingForPhone:
                Text("Scan with the Connect app on your phone")
                    .font(.headline)
                if let qrImage = pairingViewModel.qrImage {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 220, height: 220)
                }
                Text("Waiting for phone to connect…")
                    .foregroundStyle(.secondary)
                ProgressView()
            case .confirmingTrust(let deviceName):
                Text("Trust this device?")
                    .font(.headline)
                Text(deviceName)
                HStack {
                    Button("Reject") { pairingViewModel.rejectTrust() }
                    Button("Confirm") { pairingViewModel.confirmTrust() }
                        .keyboardShortcut(.defaultAction)
                }
            case .paired(let deviceName):
                Text("Paired with \(deviceName)")
                    .font(.headline)
                Button("Done") {
                    pairingViewModel.reset()
                    isPresented = false
                }
            case .failed(let reason):
                Text("Pairing failed")
                    .font(.headline)
                Text(reason)
                    .foregroundStyle(.secondary)
                Button("Close") {
                    pairingViewModel.reset()
                    isPresented = false
                }
            }
        }
        .padding(24)
        .frame(width: 320)
    }
}
