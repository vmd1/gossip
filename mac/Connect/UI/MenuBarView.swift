import SwiftUI
import UniformTypeIdentifiers

struct MenuBarView: View {
    @ObservedObject var transportManager: TransportManager
    @ObservedObject var pairingViewModel: PairingViewModel
    @ObservedObject var trustedDevicesStore: TrustedDevicesStore
    @ObservedObject var screenMirrorController: ScreenMirrorController
    @ObservedObject var fileTransferManager: FileTransferManager
    @ObservedObject var mediaControlManager: MediaControlManager

    @State private var showingPairingSheet = false
    @State private var showingDNDSetupSheet = false
    @State private var mirrorWindow: ScreenMirrorWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusRow

            if let nowPlaying = mediaControlManager.nowPlaying {
                Divider()
                NowPlayingView(nowPlaying: nowPlaying, mediaControlManager: mediaControlManager)
            }

            Divider()

            Button("Pair New Device…") {
                pairingViewModel.startPairing()
                showingPairingSheet = true
            }

            mirrorScreenRow

            Button("Do Not Disturb Sync Setup…") {
                showingDNDSetupSheet = true
            }

            Divider()

            FileDropZoneView(fileTransferManager: fileTransferManager, isConnected: isConnected)

            if !fileTransferManager.activeTransfers.isEmpty {
                Divider()
                ForEach(Array(fileTransferManager.activeTransfers.values), id: \.id) { transfer in
                    TransferRowView(transfer: transfer)
                }
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

    private var isConnected: Bool {
        if case .connected = transportManager.connectionState { return true }
        return false
    }
}

/// Drag-and-drop target for sending a file to the paired device. Unstyled by
/// design, matching the rest of this milestone's UI — the goal is working
/// transfer plumbing, not visual polish.
struct FileDropZoneView: View {
    @ObservedObject var fileTransferManager: FileTransferManager
    let isConnected: Bool

    @State private var isTargeted = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4]))
                .background(RoundedRectangle(cornerRadius: 8).fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear))
                .frame(height: 56)
                .overlay(
                    Text(isConnected ? "Drop a file here to send" : "Connect a device to send files")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                )
                .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
                    handleDrop(providers)
                }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard isConnected, let provider = providers.first else { return false }
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return false }

        _ = provider.loadObject(ofClass: URL.self) { url, error in
            guard let url else {
                DispatchQueue.main.async { errorMessage = error?.localizedDescription ?? "Couldn't read dropped file" }
                return
            }
            Task {
                do {
                    try await fileTransferManager.sendFile(at: url)
                    await MainActor.run { errorMessage = nil }
                } catch {
                    await MainActor.run { errorMessage = "Send failed: \(error.localizedDescription)" }
                }
            }
        }
        return true
    }
}

/// One row of transfer progress, shown for both outbound and inbound
/// transfers while they're in flight.
struct TransferRowView: View {
    let transfer: FileTransferManager.TransferProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: transfer.direction == .sending ? "arrow.up.circle" : "arrow.down.circle")
                Text(transfer.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.callout)

            if transfer.sizeBytes > 0 {
                ProgressView(value: Double(transfer.bytesTransferred), total: Double(transfer.sizeBytes))
            }
        }
    }
}

/// Now-playing section shown in the menu bar dropdown when the phone has an active
/// media session: title/artist/artwork plus play/pause/next/previous controls, driven
/// entirely by `MediaControlManager`'s published state and `media.command` sends.
/// Unstyled by design, matching the rest of this milestone's minimal UI.
struct NowPlayingView: View {
    let nowPlaying: NowPlayingState
    @ObservedObject var mediaControlManager: MediaControlManager

    var body: some View {
        HStack(spacing: 10) {
            artworkView

            VStack(alignment: .leading, spacing: 2) {
                Text(nowPlaying.title.isEmpty ? "Nothing playing" : nowPlaying.title)
                    .font(.subheadline)
                    .lineLimit(1)
                if !nowPlaying.artist.isEmpty {
                    Text(nowPlaying.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    mediaControlManager.previous()
                } label: {
                    Image(systemName: "backward.fill")
                }
                .buttonStyle(.borderless)

                Button {
                    nowPlaying.isPlaying ? mediaControlManager.pause() : mediaControlManager.play()
                } label: {
                    Image(systemName: nowPlaying.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderless)

                Button {
                    mediaControlManager.next()
                } label: {
                    Image(systemName: "forward.fill")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder
    private var artworkView: some View {
        if let artworkData = nowPlaying.artworkData, let nsImage = NSImage(data: artworkData) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 36, height: 36)
                .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
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
