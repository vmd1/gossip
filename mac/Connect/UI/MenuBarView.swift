import SwiftUI

struct MenuBarView: View {
    @ObservedObject var transportManager: TransportManager
    @ObservedObject var pairingViewModel: PairingViewModel
    @ObservedObject var trustedDevicesStore: TrustedDevicesStore
    @ObservedObject var screenMirrorController: ScreenMirrorController

    @State private var showingPairingSheet = false
    @State private var mirrorWindow: ScreenMirrorWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusRow

            Divider()

            Button("Pair New Device…") {
                pairingViewModel.startPairing()
                showingPairingSheet = true
            }

            mirrorScreenRow

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
    }

    /// "Mirror Screen" — sends `screen.start` over the transport purely for
    /// Android-side UI-state signaling (best-effort; ignored if not
    /// connected), then kicks off the ADB-mediated mirroring pipeline, which
    /// does NOT depend on the transport being connected — only on `adb
    /// devices` showing the phone.
    @ViewBuilder
    private var mirrorScreenRow: some View {
        switch screenMirrorController.state {
        case .idle:
            Button("Mirror Screen…") { startMirroring() }
        case .starting:
            HStack {
                ProgressView().controlSize(.small)
                Text("Starting mirroring…")
            }
        case .mirroring:
            Button("Stop Mirroring") { stopMirroring() }
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 4) {
                Text("Mirroring failed").foregroundStyle(.red)
                Text(reason).font(.caption).foregroundStyle(.secondary)
                Button("Retry") { startMirroring() }
            }
        }
    }

    private func startMirroring() {
        sendScreenSignal(type: "screen.start")
        let window = ScreenMirrorWindow(controller: screenMirrorController)
        mirrorWindow = window
        screenMirrorController.start()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func stopMirroring() {
        sendScreenSignal(type: "screen.stop")
        screenMirrorController.stop()
        mirrorWindow?.close()
        mirrorWindow = nil
    }

    private func sendScreenSignal(type: String) {
        guard case .connected(let deviceId) = transportManager.connectionState else { return }
        let envelope = Envelope(
            type: type,
            senderId: IdentityKeyStore.shared.deviceId,
            recipientId: deviceId
        )
        try? transportManager.send(envelope: envelope)
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
