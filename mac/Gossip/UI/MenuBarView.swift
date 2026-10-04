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
    @ObservedObject var ringManager: RingManager
    @ObservedObject var batterySyncManager: BatterySyncManager
    @ObservedObject var featureSettings: FeatureSettings

    @State private var settingsWindow: SettingsWindow?
    @State private var deviceSettingsWindow: DeviceSettingsWindow?
    @State private var hotspotGattClients: [String: HotspotGattClient] = [:]
    @State private var activeHotspotAutoConnect: HotspotAutoConnect?
    /// The hotspot state the phone itself just confirmed over GATT. The BLE advertisement bit and the
    /// mesh report both lag a real toggle by several seconds, so the icon trusts this until the
    /// merged state catches up (or `hotspotOverrideLifetime` passes).
    @State private var hotspotOverrides: [String: (enabled: Bool, at: Date)] = [:]
    private static let hotspotOverrideLifetime: TimeInterval = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusRow

            if notificationMirrorManager.authorizationStatus == .denied {
                notificationsDisabledRow
            }

            if let mirrorError = screenMirrorController.lastError {
                Text(mirrorError)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if featureSettings.isEnabled(.media), let nowPlaying = mediaControlManager.nowPlaying {
                Divider()
                if mediaControlManager.nowPlayingByDevice.count > 1 {
                    mediaDevicePicker
                }
                NowPlayingView(nowPlaying: nowPlaying, mediaControlManager: mediaControlManager)
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
                        HStack(spacing: 8) {
                            // Green = connected directly, blue = reachable over the mesh, grey = not connected.
                            let connectivity = DeviceConnectivity.classify(
                                device.deviceId, directIds: transportManager.connectedDeviceIds, meshIds: transportManager.meshReachableDeviceIds
                            )
                            Image(systemName: device.deviceType.symbolName)
                                .foregroundStyle(Self.color(for: connectivity))
                                .frame(width: 18)
                                .help(Self.description(of: connectivity))
                            Text(device.deviceName)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 4)
                            deviceActionButtons(for: device)
                        }
                        deviceSubtitleRow(for: device)
                    }
                }
            }

            Divider()

            HStack {
                Button("Quit Gossip") {
                    NSApplication.shared.terminate(nil)
                }
                Spacer()
                Button {
                    if let existing = settingsWindow, existing.isVisible {
                        existing.makeKeyAndOrderFront(nil)
                    } else {
                        let window = SettingsWindow(
                            featureSettings: featureSettings,
                            pairingViewModel: pairingViewModel,
                            notificationMirrorManager: notificationMirrorManager
                        )
                        settingsWindow = window
                        window.makeKeyAndOrderFront(nil)
                    }
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings…")
            }
        }
        .padding(12)
        .frame(width: 300)
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
        let underlying = underlyingHotspotState(for: deviceId)
        if let override = hotspotOverrides[deviceId], Date().timeIntervalSince(override.at) < Self.hotspotOverrideLifetime,
           underlying?.enabled != override.enabled {
            return HotspotState(enabled: override.enabled, ssid: override.enabled ? underlying?.ssid : nil)
        }
        return underlying
    }

    private func underlyingHotspotState(for deviceId: String) -> HotspotState? {
        let meshState = hotspotStateManager.hotspotStateBySenderId[deviceId]
        guard bleProximityMonitor.nearbyDeviceIds.contains(deviceId) else { return meshState }
        let bleOn = bleProximityMonitor.isHotspotOn(deviceId: deviceId)
        if let meshState {
            return HotspotState(enabled: bleOn, ssid: meshState.ssid)
        }
        return HotspotState(enabled: bleOn, ssid: nil)
    }

    /// Requests `enable` from the phone over BLE GATT, then joins its network on a successful "on".
    /// Deliberately silent in the UI — the hotspot icon's own state is the feedback — but failures
    /// are written to the BLE debug log.
    private func requestHotspot(for device: TrustedDevice, enable: Bool) {
        guard let peripheralId = bleProximityMonitor.peripheralIdentifierByDeviceId[device.deviceId] else {
            return
        }
        let client = HotspotGattClient()
        hotspotGattClients[device.deviceId] = client
        client.requestToggle(providerId: device.deviceId, peripheralIdentifier: peripheralId, enable: enable) { result in
            DispatchQueue.main.async {
                hotspotGattClients[device.deviceId] = nil
                switch result {
                case .failed(let reason):
                    gossipError("Gossip: " + "requestHotspot failed: \(reason)")
                case .success(let enabled, let ssid, let passphrase):
                    hotspotOverrides[device.deviceId] = (enabled, Date())
                    guard enable, enabled, let ssid, let passphrase else { return }
                    let autoConnect = HotspotAutoConnect()
                    activeHotspotAutoConnect = autoConnect
                    autoConnect.connect(ssid: ssid, passphrase: passphrase) { connected in
                        if !connected { NSLog("Gossip: " + "requestHotspot: could not auto-connect to \(ssid)") }
                    }
                }
            }
        }
    }

    /// The row's actions, as compact icons: Ring, Mirror Screen, Instant Hotspot (tinted blue while on,
    /// as before), and "⋯" for per-device settings. A disabled feature's icon simply doesn't appear.
    @ViewBuilder
    private func deviceActionButtons(for device: TrustedDevice) -> some View {
        HStack(spacing: 8) {
            if featureSettings.isEnabled(.findDevice) {
                // Press to ring; blue while it's ringing; press again to stop.
                let ringing = ringManager.ringingPeers.contains(device.deviceId)
                Button { ringManager.toggleRing(device.deviceId) } label: { Image(systemName: "bell.and.waves.left.and.right") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(ringing ? Color.blue : Color.secondary)
                    .help(ringing ? "Stop ringing \(device.deviceName)" : "Ring \(device.deviceName)")
            }
            if device.deviceType != .mac, featureSettings.isEnabled(.screenMirroring) {
                mirrorButton(for: device)
            }
            if featureSettings.isEnabled(.hotspot), device.deviceType == .androidPhone, let state = mergedHotspotState(for: device.deviceId) {
                hotspotButton(for: device, state: state)
            }
            // Per-device settings open a plain NSWindow, not an inline control: a TextField inside
            // this MenuBarExtra(.window) panel can never take keyboard focus (the panel resigns key
            // and dismisses itself as soon as the field is clicked).
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
            .help("Settings for \(device.deviceName)")
        }
    }

    /// Mirror Screen icon: spinner while starting, blue while mirroring (click to stop). Only one
    /// mirroring session runs at a time, so every other row's button is disabled while one is active.
    @ViewBuilder
    private func mirrorButton(for device: TrustedDevice) -> some View {
        let isThisDevice = screenMirrorController.mirroringDeviceId == device.deviceId
        switch (screenMirrorController.state, isThisDevice) {
        case (.idle, _):
            Button { startMirroring(for: device) } label: { Image(systemName: "rectangle.on.rectangle") }
                .buttonStyle(.borderless)
                .help("Mirror \(device.deviceName)'s screen")
        case (.starting, true):
            ProgressView().controlSize(.small)
        case (.mirroring, true):
            Button { stopMirroring() } label: { Image(systemName: "rectangle.on.rectangle") }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.blue)
                .help("Stop mirroring")
        case (.starting, false), (.mirroring, false):
            Button {} label: { Image(systemName: "rectangle.on.rectangle") }
                .buttonStyle(.borderless)
                .disabled(true)
        }
    }

    /// Hotspot on/off icon for a trusted phone, driven by the merged mesh + BLE state. Tapping
    /// requests the opposite of the currently known state.
    @ViewBuilder
    private func hotspotButton(for device: TrustedDevice, state: HotspotState) -> some View {
        if hotspotGattClients[device.deviceId] != nil {
            // Request in flight: a spinner, like the screen-mirroring button while it starts.
            ProgressView().controlSize(.small)
        } else {
            Button {
                requestHotspot(for: device, enable: !state.enabled)
            } label: {
                // "personalhotspot.slash" isn't a real SF Symbol — off state is conveyed by tint alone.
                Image(systemName: "personalhotspot")
            }
            .buttonStyle(.borderless)
            // On the `Button` itself (not the inner `Image`): `.borderless` tinting overrides the latter.
            // Explicit `.blue`, not `Color.accentColor`, which can be set to gray in System Settings.
            .foregroundStyle(state.enabled ? Color.blue : Color.secondary)
            .help(state.enabled ? "Instant Hotspot is on\(state.ssid.map { " (\($0))" } ?? "") — click to turn off" : "Instant Hotspot is off — click to request")
        }
    }

    private func lowBattery(_ device: TrustedDevice) -> Bool {
        guard featureSettings.isEnabled(.battery), let b = batterySyncManager.batteryBySenderId[device.deviceId] else { return false }
        return b.level <= BatterySyncManager.lowThreshold && !b.isCharging
    }

    /// One-line status under the name: battery icon + level, then Bluetooth-nearby (hotspot/mirroring state shows on their icons).
    @ViewBuilder
    private func deviceSubtitleRow(for device: TrustedDevice) -> some View {
        let battery = featureSettings.isEnabled(.battery) ? batterySyncManager.batteryBySenderId[device.deviceId] : nil
        var parts: [String] = []
        let _ = {
            if bleProximityMonitor.nearbyDeviceIds.contains(device.deviceId) { parts.append("Nearby") }
        }()
        if battery != nil || !parts.isEmpty {
            HStack(spacing: 4) {
                if let battery {
                    Image(systemName: Self.batterySymbol(battery))
                        .foregroundStyle(lowBattery(device) ? Color.red : (battery.isCharging ? Color.green : Color.secondary))
                    Text("\(battery.level)%")
                        .foregroundStyle(lowBattery(device) ? Color.red : Color.secondary)
                }
                if battery != nil && !parts.isEmpty { Text("·").foregroundStyle(.secondary) }
                if !parts.isEmpty { Text(parts.joined(separator: " · ")).foregroundStyle(.secondary) }
            }
            .font(.caption)
            .lineLimit(1)
            .padding(.leading, 26)
            .help(battery.map { $0.isCharging ? "Charging" : "On battery" } ?? "")
        }
    }

    static func color(for connectivity: Connectivity) -> Color {
        switch connectivity {
        case .direct: return .green
        case .mesh: return .blue
        case .none: return .secondary
        }
    }

    static func description(of connectivity: Connectivity) -> String {
        switch connectivity {
        case .direct: return "Connected"
        case .mesh: return "Connected through another device"
        case .none: return "Not connected"
        }
    }

    static func batterySymbol(_ b: BatteryState) -> String {
        if b.isCharging { return "battery.100.bolt" }
        switch b.level {
        case 88...: return "battery.100"
        case 63...: return "battery.75"
        case 38...: return "battery.50"
        case 13...: return "battery.25"
        default: return "battery.0"
        }
    }

    /// Starts on-device screen mirroring for `device`: negotiated over the mesh, streamed from the
    /// phone over its WebSocket bridge, shown in Gossip's own window. See `ScreenMirrorController`.
    private func startMirroring(for device: TrustedDevice) {
        screenMirrorController.start(deviceId: device.deviceId, deviceName: device.deviceName, transport: transportManager)
    }

    private func stopMirroring() {
        screenMirrorController.stop()
    }

    /// Warns when notification permission is off, since mirrored notifications
    /// otherwise fail completely silently — `UNUserNotificationCenter.add(_:)` reports
    /// no error in this case, it just never shows anything. See `NotificationMirrorManager`.
    @ViewBuilder
    private var notificationsDisabledRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Notifications are disabled for Gossip")
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
        case .connected:
            return "Connected"
        }
    }

    private var isConnected: Bool {
        if case .connected = transportManager.connectionState { return true }
        return false
    }
}

/// Editable field for `TrustedDevice.fallbackHost`. The owner holds the text and saves it; this view
/// calls `onCommit` on Return and ~0.8s after the user stops typing (so a fallback dial never fires
/// against a half-typed address on every keystroke, but a value is never lost just because the user
/// closed the window or clicked Done without pressing Return). Matches Android's
/// `PairedDevicesScreen.FallbackHostField`.
struct FallbackHostField: View {
    @Binding var text: String
    var onCommit: () -> Void

    var body: some View {
        TextField("Fallback IP (e.g. Tailscale)", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.caption)
            .onSubmit { onCommit() }
            .task(id: text) {
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard !Task.isCancelled else { return }
                onCommit()
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

    /// The safety code typed by the user; Confirm stays disabled until it matches (see `PairingCode.entryMatches`).
    @State private var enteredCode = ""

    private var failureReason: String? {
        if case .failed(let reason) = pairingViewModel.state { return reason }
        return nil
    }

    private var isPaired: Bool {
        if case .paired = pairingViewModel.state { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 16) {
            switch pairingViewModel.state {
            case .idle:
                Text("Preparing…")
            case .showingQR, .waitingForPhone:
                Text("Scan with the Gossip app on your phone")
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
            case .confirmingTrust(let deviceName, let code):
                Text("Trust this device?")
                    .font(.headline)
                Text(deviceName)
                Text("Type the 6-digit code shown on the other device. Only continue if you are looking at that device right now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                TextField("123 456", text: $enteredCode)
                    .font(.system(.title2, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                HStack {
                    Button("Reject") { enteredCode = ""; pairingViewModel.rejectTrust() }
                    Button("Confirm") { enteredCode = ""; pairingViewModel.confirmTrust() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!PairingCode.entryMatches(enteredCode, expected: code))
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
        // Once paired, show the confirmation briefly and close by itself so setup can carry on.
        .task(id: isPaired) {
            guard isPaired else { return }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, isPaired else { return }
            pairingViewModel.reset()
            onDismiss()
        }
        // A failure message doesn't linger: 10 seconds after pairing fails, the sheet closes itself.
        // (`.task(id:)` restarts — cancelling the sleep — whenever the failure text changes or clears.)
        .task(id: failureReason) {
            guard failureReason != nil else { return }
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, failureReason != nil else { return }
            pairingViewModel.reset()
            onDismiss()
        }
        .padding(24)
        .frame(width: 320)
    }
}
