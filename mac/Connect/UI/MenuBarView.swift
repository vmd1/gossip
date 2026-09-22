import SwiftUI

struct MenuBarView: View {
    @ObservedObject var transportManager: TransportManager
    @ObservedObject var pairingViewModel: PairingViewModel
    @ObservedObject var trustedDevicesStore: TrustedDevicesStore
    @ObservedObject var mediaControlManager: MediaControlManager

    @State private var showingPairingSheet = false

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
