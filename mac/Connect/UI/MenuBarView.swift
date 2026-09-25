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
    @ObservedObject var hotspotStateManager: HotspotStateManager

    @State private var pairingWindow: PairingWindow?
    @State private var dndSetupWindow: DNDSetupWindow?
    @State private var adbPairingWindow: ADBPairingWindow?
    @State private var adbPairingCancellable: AnyCancellable?
    @State private var deviceSettingsWindow: DeviceSettingsWindow?
    @State private var onboardingWindow: OnboardingWindow?
    @State private var hotspotGattClients: [String: HotspotGattClient] = [:]
    @State private var hotspotStatusMessages: [String: String] = [:]
    @State private var activeHotspotAutoConnect: HotspotAutoConnect?

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
                    VStack(alignment: .leading, spacing: 2) {
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
                            if device.deviceType == .androidPhone, let state = mergedHotspotState(for: device.deviceId) {
                                hotspotButton(for: device, state: state)
                            }
                            deviceSettingsMenu(for: device)
                        }
                        if let status = hotspotStatusMessages[device.deviceId] {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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

    /// Merges the two hotspot-state sources: `hotspot.state_update`'s mesh report
    /// (`HotspotStateManager`, richer — carries the SSID, works at any range) and the
    /// BLE advertisement's own on/off bit (`BLEProximityMonitor.isHotspotOn`, live
    /// even with no mesh connection at all). Live-confirmed real gap this fixes: with
    /// mesh as the only source, this Mac's hotspot indicator went stale the moment its
    /// mesh connection to the phone dropped, with nothing to correct it — pressing the
    /// button against that stale belief then sent the wrong request. Prefers the BLE
    /// bit's `enabled` value whenever the phone is currently BLE-nearby (fresher by
    /// construction), keeping the mesh report's `ssid` either way; falls back to a
    /// BLE-only or mesh-only state when just one source has data, and to `nil` when
    /// neither does.
    private func mergedHotspotState(for deviceId: String) -> HotspotState? {
        let meshState = hotspotStateManager.hotspotStateBySenderId[deviceId]
        guard bleProximityMonitor.nearbyDeviceIds.contains(deviceId) else { return meshState }
        let bleOn = bleProximityMonitor.isHotspotOn(deviceId: deviceId)
        if let meshState {
            return HotspotState(enabled: bleOn, ssid: meshState.ssid)
        }
        return HotspotState(enabled: bleOn, ssid: nil)
    }

    /// Hotspot on/off icon for a trusted phone, driven by `hotspot.state_update` mesh
    /// reports (`HotspotStateManager`) rather than BLE proximity — shown for every
    /// trusted phone this Mac has a reported state for, whether or not it's currently
    /// BLE-nearby (a request only actually works while nearby, per
    /// `docs/ble-hotspot-protocol.md`, but the on/off indicator itself is a live mesh
    /// signal, independent of that). Tapping requests the opposite of the currently
    /// known state. First cut of this feature's UI: status is a plain caption line
    /// under the row, not a polished progress/retry flow.
    @ViewBuilder
    private func hotspotButton(for device: TrustedDevice, state: HotspotState) -> some View {
        let isInFlight = hotspotGattClients[device.deviceId] != nil
        Button {
            requestHotspot(for: device, enable: !state.enabled)
        } label: {
            // "personalhotspot.slash" isn't a real SF Symbol (confirmed: only
            // "personalhotspot" itself exists) — off state is conveyed by tint alone,
            // same symbol either way.
            Image(systemName: "personalhotspot")
        }
        .buttonStyle(.borderless)
        // Applied to the `Button` itself, not inside its `label` closure — confirmed
        // live that a `.foregroundStyle` on the inner `Image` alone is overridden by
        // `Button`'s own `.borderless` style tinting on macOS and never actually
        // reflects a state change, even though the underlying data updates correctly.
        // Explicit `.blue`, not `Color.accentColor` — the system accent color can
        // itself be set to gray/graphite in System Settings, which would make an
        // "on" state visually indistinguishable from the "off" `.secondary` state
        // regardless of this fix.
        .foregroundStyle(state.enabled ? Color.blue : Color.secondary)
        .disabled(isInFlight)
        .help(state.enabled ? "Instant Hotspot is on\(state.ssid.map { " (\($0))" } ?? "") — click to turn off" : "Instant Hotspot is off — click to request")
    }

    private func requestHotspot(for device: TrustedDevice, enable: Bool) {
        guard let peripheralId = bleProximityMonitor.peripheralIdentifierByDeviceId[device.deviceId] else {
            hotspotStatusMessages[device.deviceId] = "Device is no longer nearby"
            return
        }
        hotspotStatusMessages[device.deviceId] = enable ? "Requesting…" : "Requesting off…"
        let client = HotspotGattClient()
        hotspotGattClients[device.deviceId] = client
        client.requestToggle(providerId: device.deviceId, peripheralIdentifier: peripheralId, enable: enable) { result in
            DispatchQueue.main.async {
                hotspotGattClients[device.deviceId] = nil
                switch result {
                case .failed(let reason):
                    hotspotStatusMessages[device.deviceId] = "Failed: \(reason)"
                case .success(let enabled, let ssid, let passphrase):
                    if !enable {
                        hotspotStatusMessages[device.deviceId] = enabled ? "That device kept its hotspot on" : "Hotspot turned off"
                    } else if !enabled {
                        hotspotStatusMessages[device.deviceId] = "That device declined the request"
                    } else if let ssid, let passphrase {
                        hotspotStatusMessages[device.deviceId] = "Connecting to \(ssid)…"
                        let autoConnect = HotspotAutoConnect()
                        activeHotspotAutoConnect = autoConnect
                        autoConnect.connect(ssid: ssid, passphrase: passphrase) { connected in
                            DispatchQueue.main.async {
                                hotspotStatusMessages[device.deviceId] = connected ? "Connected to \(ssid)" : "Hotspot on — could not auto-connect, join manually"
                            }
                        }
                    } else {
                        hotspotStatusMessages[device.deviceId] = "Hotspot on — connect manually"
                    }
                }
            }
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
