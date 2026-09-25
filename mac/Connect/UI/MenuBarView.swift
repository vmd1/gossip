import SwiftUI
import UserNotifications
import Combine

struct MenuBarView: View {
    @ObservedObject var transportManager: TransportManager
    @ObservedObject var pairingViewModel: PairingViewModel
    @ObservedObject var trustedDevicesStore: TrustedDevicesStore
    @ObservedObject var screenMirrorController: ScreenMirrorController
    @ObservedObject var mediaControlManager: MediaControlManager
    @ObservedObject var notificationMirrorManager: NotificationMirrorManager
    let rosterGossipManager: RosterGossipManager
    @ObservedObject var bleProximityMonitor: BLEProximityMonitor

    @State private var pairingWindow: PairingWindow?
    @State private var dndSetupWindow: DNDSetupWindow?
    @State private var adbPairingWindow: ADBPairingWindow?
    @State private var adbPairingCancellable: AnyCancellable?
    @State private var deviceSettingsWindow: DeviceSettingsWindow?
    @State private var onboardingWindow: OnboardingWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusRow

            if notificationMirrorManager.authorizationStatus == .denied {
                notificationsDisabledRow
            }

            if let nowPlaying = mediaControlManager.nowPlaying {
                Divider()
                if mediaControlManager.nowPlayingByDevice.count > 1 {
                    mediaDevicePicker
                }
                NowPlayingView(nowPlaying: nowPlaying, mediaControlManager: mediaControlManager)
            }

            Divider()

            Button("Pair New Device…") {
                pairingViewModel.startPairing()
                let window = PairingWindow(pairingViewModel: pairingViewModel)
                pairingWindow = window
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }

            // Only shown before first-run onboarding completes — after that, DND setup is
            // reachable via "Run Setup Again…"'s permissions step (which has its own
            // "Set Up DND Sync…" button), so this standalone entry would just be a
            // redundant second way to the same window cluttering the everyday menu.
            if !OnboardingPreferences.isCompleted {
                Button("Do Not Disturb Sync Setup…") {
                    let window = DNDSetupWindow()
                    dndSetupWindow = window
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }

            Button("Run Setup Again…") {
                let window = OnboardingWindow(
                    onPairNewDevice: {
                        pairingViewModel.startPairing()
                        let pairing = PairingWindow(pairingViewModel: pairingViewModel)
                        pairingWindow = pairing
                        pairing.makeKeyAndOrderFront(nil)
                        NSApp.activate(ignoringOtherApps: true)
                    },
                    onOpenDNDSetup: {
                        let dnd = DNDSetupWindow()
                        dndSetupWindow = dnd
                        dnd.makeKeyAndOrderFront(nil)
                        NSApp.activate(ignoringOtherApps: true)
                    },
                    notificationAuthorizationStatus: { notificationMirrorManager.authorizationStatus },
                    onOpenNotificationSettings: {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                )
                onboardingWindow = window
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
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
                        Image(systemName: device.deviceType.symbolName)
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text(device.deviceName)
                        if bleProximityMonitor.nearbyDeviceIds.contains(device.deviceId) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .foregroundStyle(.blue)
                                .help("Nearby over Bluetooth")
                        }
                        Spacer()
                        if device.deviceType != .mac {
                            mirrorButton(for: device)
                        }
                        deviceSettingsMenu(for: device)
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
    }

    /// Per-device "Mirror"/"Stop Mirroring" button shown next to "Forget" in the
    /// Trusted Devices list, so the user picks *which* Android device to mirror now
    /// that more than one can be trusted at once — `ScreenMirrorController` only ever
    /// runs one `scrcpy` session at a time, so every other row's button is disabled
    /// while one is active.
    @ViewBuilder
    private func mirrorButton(for device: TrustedDevice) -> some View {
        let isThisDevice = screenMirrorController.mirroringDeviceId == device.deviceId
        switch (screenMirrorController.state, isThisDevice) {
        case (.idle, _):
            Button("Mirror") { startMirroring(for: device) }
                .buttonStyle(.borderless)
        case (.starting, true):
            ProgressView().controlSize(.small)
        case (.mirroring, true):
            Button("Stop Mirroring") { stopMirroring() }
                .buttonStyle(.borderless)
        case (.starting, false), (.mirroring, false):
            Button("Mirror") {}
                .buttonStyle(.borderless)
                .disabled(true)
        }
    }

    /// Settings for one specific trusted device that don't need to be visible on the
    /// home row: fallback-host override and revoking trust today; per-pair BLE-driven
    /// settings (Lock-on-Leave, auto-hotspot) land here too once built. Kept separate
    /// from `mirrorButton`, which stays a direct row action since it's used often
    /// enough to want one click, not two.
    ///
    /// Opens a plain `NSWindow` (`DeviceSettingsWindow`) rather than an inline `Menu` —
    /// a `TextField` inside a `Menu` shown from this app's `MenuBarExtra(.window)`
    /// panel never gets a chance to take keyboard focus, because the panel resigns key
    /// and dismisses itself the instant the field is clicked. Previously only the
    /// fallback-host field got this treatment, with "Forget" left as a plain inline
    /// menu item — consolidated so the whole per-device settings surface is one
    /// consistent window instead of half a menu, half a window.
    @ViewBuilder
    private func deviceSettingsMenu(for device: TrustedDevice) -> some View {
        Button {
            let window = DeviceSettingsWindow(
                device: device,
                trustedDevicesStore: trustedDevicesStore,
                onForget: { rosterGossipManager.revoke(deviceId: device.deviceId) }
            )
            deviceSettingsWindow = window
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .buttonStyle(.borderless)
    }

    /// Before launching the mirroring pipeline, makes sure `adb` already sees an
    /// authorized device matching *this specific* trusted device (preferring one
    /// whose `ip:port` adb serial matches this device's known Connect transport IP,
    /// so picking "Mirror" on the tablet doesn't accidentally mirror the phone);
    /// if not, opens the QR wireless-pairing flow first and only starts mirroring
    /// once it reaches `.connected`. Either way, mirroring itself is just `scrcpy`
    /// launched as a subprocess — it opens and owns its own window, Connect doesn't
    /// render anything itself. See `ScreenMirrorController`.
    private func startMirroring(for device: TrustedDevice) {
        sendScreenSignal(type: "screen.start", to: device.deviceId)
        guard let adbPath = ADBClient.resolveADBPath() else {
            screenMirrorController.start(deviceId: device.deviceId) // surfaces the "adb/scrcpy not found" failure state
            return
        }

        let targetIP = transportManager.ipAddress(for: device.deviceId)
        DispatchQueue.global(qos: .userInitiated).async {
            let output = (try? ADBClient.run(["devices", "-l"])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            // If we know this device's IP, only match a serial for that exact IP —
            // never fall back to "whichever device adb happens to see first" once
            // there's a specific device to target. Only fall back to that (matching
            // today's pre-mesh behavior) when we have no IP to go on at all, e.g. this
            // device isn't currently connected over the Connect transport.
            let existingSerial = targetIP.map { ADBWirelessPairing.firstAuthorizedSerial(output, matchingIP: $0) }
                ?? ADBWirelessPairing.firstAuthorizedSerial(output)
            DispatchQueue.main.async {
                if let existingSerial {
                    screenMirrorController.start(serial: existingSerial, deviceId: device.deviceId)
                } else {
                    beginADBPairing(adbPath: adbPath, device: device, trustedPeerIP: targetIP)
                }
            }
        }
    }

    private func beginADBPairing(adbPath: String, device: TrustedDevice, trustedPeerIP: String?) {
        let pairing = ADBWirelessPairing(adbPath: adbPath)
        pairing.trustedPeerIP = trustedPeerIP
        let window = ADBPairingWindow(pairing: pairing)
        adbPairingWindow = window

        adbPairingCancellable = pairing.$state.sink { state in
            if case .connected(let serial, _) = state {
                adbPairingCancellable = nil
                window.close()
                adbPairingWindow = nil
                screenMirrorController.start(serial: serial, deviceId: device.deviceId)
            }
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func stopMirroring() {
        if let deviceId = screenMirrorController.mirroringDeviceId {
            sendScreenSignal(type: "screen.stop", to: deviceId)
        }
        screenMirrorController.stop()
    }

    private func sendScreenSignal(type: String, to deviceId: String) {
        let envelope = Envelope(
            type: type,
            senderId: IdentityKeyStore.shared.deviceId,
            recipientId: deviceId
        )
        try? transportManager.send(envelope: envelope)
    }

    /// Warns when notification permission is off, since mirrored notifications
    /// otherwise fail completely silently — `UNUserNotificationCenter.add(_:)` reports
    /// no error in this case, it just never shows anything. See `NotificationMirrorManager`.
    @ViewBuilder
    private var notificationsDisabledRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Notifications are disabled for Connect")
                .foregroundStyle(.red)
                .font(.callout)
            Button("Open Notification Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    /// Shown only when more than one device is currently reporting a media session —
    /// lets the user pick which one the now-playing card and playback controls target,
    /// rather than always defaulting to whichever reported most recently.
    private var mediaDevicePicker: some View {
        Picker("Now playing on", selection: Binding(
            get: { mediaControlManager.selectedDeviceId ?? mediaControlManager.nowPlayingByDevice.keys.first ?? "" },
            set: { mediaControlManager.selectedDeviceId = $0 }
        )) {
            ForEach(Array(mediaControlManager.nowPlayingByDevice.keys), id: \.self) { deviceId in
                Text(trustedDevicesStore.device(for: deviceId)?.deviceName ?? deviceId)
                    .tag(deviceId)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
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

/// Editable field for `TrustedDevice.fallbackHost`, committed on Return/focus loss rather
/// than every keystroke, so a fallback dial attempt never fires against a half-typed
/// address — matches Android's `PairedDevicesScreen.FallbackHostField`.
struct FallbackHostField: View {
    let device: TrustedDevice
    @ObservedObject var trustedDevicesStore: TrustedDevicesStore

    @State private var text: String = ""

    var body: some View {
        TextField("Fallback IP (e.g. Tailscale)", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.caption)
            .onAppear { text = device.fallbackHost ?? "" }
            .onSubmit {
                trustedDevicesStore.setFallbackHost(deviceId: device.deviceId, fallbackHost: text)
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
    /// Called when the user dismisses this view (Done/Close). Hosted in a
    /// plain `NSWindow` (`PairingWindow`) rather than a SwiftUI `.sheet` —
    /// presenting a `.sheet` from inside a `.menuBarExtraStyle(.window)`
    /// content view causes the whole menu-bar panel to resign key and
    /// auto-dismiss itself (and everything presented on top of it) the
    /// moment any button inside it is pressed, which is why pairing could
    /// never actually complete: the QR/confirm UI vanished before the user
    /// could interact with it.
    var onDismiss: () -> Void

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
                    onDismiss()
                }
            case .failed(let reason):
                Text("Pairing failed")
                    .font(.headline)
                Text(reason)
                    .foregroundStyle(.secondary)
                Button("Close") {
                    pairingViewModel.reset()
                    onDismiss()
                }
            }
        }
        .padding(24)
        .frame(width: 320)
    }
}
