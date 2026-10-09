import SwiftUI
import AppKit
import UserNotifications

/// Gossip's Settings window: per-feature on/off toggles for this Mac (all on by default) plus
/// the setup actions that used to live in the menu-bar panel (pairing, DND sync setup, re-running
/// onboarding). A plain `NSWindow` rather than a sheet/popover for the same reason as
/// `PairingWindow`/`DeviceSettingsWindow`: controls inside the `MenuBarExtra(.window)` panel
/// make it dismiss itself. Owns the secondary windows it opens so they stay alive.
final class SettingsWindow: NSWindow {
    private let pairingViewModel: PairingViewModel
    private let notificationMirrorManager: NotificationMirrorManager
    private var pairingWindow: PairingWindow?
    private var dndSetupWindow: DNDSetupWindow?
    private var onboardingWindow: OnboardingWindow?

    init(featureSettings: FeatureSettings, transportManager: TransportManager, pairingViewModel: PairingViewModel, notificationMirrorManager: NotificationMirrorManager) {
        self.pairingViewModel = pairingViewModel
        self.notificationMirrorManager = notificationMirrorManager
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "Gossip Settings"
        isReleasedWhenClosed = false
        contentView = NSHostingView(
            rootView: SettingsView(
                features: featureSettings,
                transport: transportManager,
                onPairNewDevice: { [weak self] in self?.openPairing() },
                onOpenDNDSetup: { [weak self] in self?.openDNDSetup() },
                onRunSetupAgain: { [weak self] in self?.openOnboarding() }
            )
        )
        center()
    }

    private func show(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openPairing() {
        pairingViewModel.startPairing()
        let window = PairingWindow(pairingViewModel: pairingViewModel)
        pairingWindow = window
        show(window)
    }

    private func openDNDSetup() {
        let window = DNDSetupWindow()
        dndSetupWindow = window
        show(window)
    }

    private func openOnboarding() {
        let window = OnboardingWindow(
            onPairNewDevice: { [weak self] in self?.openPairing() },
            onOpenDNDSetup: { [weak self] in self?.openDNDSetup() },
            notificationAuthorizationStatus: { [weak self] in self?.notificationMirrorManager.authorizationStatus ?? .notDetermined },
            onOpenNotificationSettings: {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                    NSWorkspace.shared.open(url)
                }
            }
        )
        onboardingWindow = window
        show(window)
    }
}

private struct SettingsView: View {
    @ObservedObject var features: FeatureSettings
    @ObservedObject var transport: TransportManager
    let onPairNewDevice: () -> Void
    let onOpenDNDSetup: () -> Void
    let onRunSetupAgain: () -> Void

    @ObservedObject private var universalControl = UniversalControlCoordinator.shared
    @State private var commandMapping = UniversalControlSettings.commandMapping
    @State private var typingMode = UniversalControlSettings.typingMode
    @State private var launcherEnabled = LauncherPreference.autoInstall
    @State private var launcherMessage: String?

    var body: some View {
        Form {
            Section {
                ForEach(Feature.allCases) { feature in
                    Toggle(isOn: Binding(
                        get: { _ = features.version; return features.isEnabled(feature) },
                        set: { features.setEnabled(feature, $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(feature.title)
                            Text(feature.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Features")
            } footer: {
                Text("Turning a feature off stops this Mac from sending or receiving it at all. Your other devices keep their own settings.")
                    .font(.caption)
            }

            RelaySettingsSection(settings: .shared, transport: transport)

            Section {
                Button("Arrange Devices…") { universalControl.showLayoutWindow() }
                    .disabled(!features.isEnabled(.universalControl))
                permissionRow(
                    "Accessibility", granted: universalControl.accessibilityGranted,
                    detail: "Lets Gossip capture and redirect your mouse and keyboard.",
                    request: { ControlEventTap.requestAccessibility(); ControlEventTap.openAccessibilitySettings() }
                )
                permissionRow(
                    "Input Monitoring", granted: universalControl.inputMonitoringGranted,
                    detail: "Lets Gossip see keystrokes to forward them.",
                    request: { ControlEventTap.requestInputMonitoring(); ControlEventTap.openInputMonitoringSettings() }
                )
                Picker("Command key acts as", selection: Binding(
                    get: { commandMapping },
                    set: { commandMapping = $0; UniversalControlSettings.commandMapping = $0 }
                )) {
                    Text("Control (Cmd+C copies)").tag(HIDKeyTable.CommandMapping.control)
                    Text("Meta / Windows key").tag(HIDKeyTable.CommandMapping.meta)
                }
                Picker("Typing", selection: Binding(
                    get: { typingMode },
                    set: { typingMode = $0; UniversalControlSettings.typingMode = $0 }
                )) {
                    Text("Characters (best for non-US layouts)").tag(ControlTypingMode.characters)
                    Text("Key codes").tag(ControlTypingMode.keys)
                }
            } header: {
                Text("Universal Control")
            } footer: {
                Text("Push the pointer off the edge of your Mac's screen towards a device you placed in Arrange Devices. Press Control+Option+Command+Esc to jump back at any time. Keystrokes in password fields aren't visible to Gossip (macOS secure input).")
                    .font(.caption)
            }

            Section {
                Toggle(isOn: Binding(
                    get: { launcherEnabled },
                    set: { on in
                        LauncherPreference.autoInstall = on
                        launcherEnabled = on
                        if on {
                            LauncherSetup.ensureInstalled()
                            if case .notApplicable(let reason) = LauncherInstaller().status() { launcherMessage = reason } else { launcherMessage = nil }
                        } else {
                            launcherMessage = "To remove it, delete “Device Mirroring” from your Applications folder."
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Device Mirroring app")
                        Text("Keeps a “Device Mirroring” app next to Gossip so you can open the device list from Spotlight or Launchpad.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let launcherMessage {
                    Text(launcherMessage).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Apps")
            }

            Section("Devices & setup") {
                Button("Pair New Device…", action: onPairNewDevice)
                Button("Do Not Disturb Sync Setup…", action: onOpenDNDSetup)
                Button("Run Setup Again…", action: onRunSetupAgain)
            }

            Section {
                Text(Self.versionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    /// "Gossip 17" for a release build, "Gossip 1.0" for a local one (the release number is stamped into the
    /// marketing version by the release workflow); the build number is appended when it differs.
    static var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String
        if let build, build != short, build != "1" { return "Gossip \(short) (\(build))" }
        return "Gossip \(short)"
    }

    @ViewBuilder
    private func permissionRow(_ title: String, granted: Bool, detail: String, request: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
            } else {
                Button("Open System Settings", action: request)
            }
        }
    }
}
