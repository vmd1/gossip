import SwiftUI
import AppKit

/// Hosts one device's settings (fallback host, Forget) in a plain `NSWindow` — same
/// reason as `PairingWindow`/`DNDSetupWindow`: this app's menu bar
/// content is a `MenuBarExtra(.window)` panel, and any interactive control shown from
/// inside it (a `.sheet`, or a `TextField`/`Button` embedded directly in a `Menu`)
/// causes the panel to resign key and dismiss itself the instant it's touched — a
/// `TextField` in particular never even gets a chance to take keyboard focus. A normal
/// titled window has no such relationship to the menu-bar panel. Previously this only
/// covered the fallback-host field, with "Forget" left as a plain inline `Menu` item in
/// `MenuBarView` — consolidated into one settings window per the same reasoning, so the
/// whole per-device settings surface behaves consistently rather than half opening a
/// real window and half staying an inline menu.
final class DeviceSettingsWindow: NSWindow {
    init(device: TrustedDevice, trustedDevicesStore: TrustedDevicesStore, onForget: @escaping () -> Void) {
        let initialFrame = NSRect(x: 0, y: 0, width: 340, height: 200)
        super.init(
            contentRect: initialFrame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "\(device.deviceName) Settings"
        isReleasedWhenClosed = false

        let hostingView = NSHostingView(
            rootView: DeviceSettingsContentView(
                device: device,
                trustedDevicesStore: trustedDevicesStore,
                onForget: { [weak self] in
                    onForget()
                    self?.close()
                },
                onDone: { [weak self] in
                    self?.close()
                }
            )
        )
        contentView = hostingView
        center()
    }
}

private struct DeviceSettingsContentView: View {
    let device: TrustedDevice
    @ObservedObject var trustedDevicesStore: TrustedDevicesStore
    var onForget: () -> Void
    var onDone: () -> Void

    @State private var showForgetConfirmation = false
    @State private var fallbackText: String
    @State private var fallbackInvalid = false

    init(device: TrustedDevice, trustedDevicesStore: TrustedDevicesStore, onForget: @escaping () -> Void, onDone: @escaping () -> Void) {
        self.device = device
        _fallbackText = State(initialValue: device.fallbackHost ?? "")
        self.trustedDevicesStore = trustedDevicesStore
        self.onForget = onForget
        self.onDone = onDone
    }

    /// Saves the typed address if it differs from what's stored (a no-op otherwise, so repeated
    /// commits don't rewrite the store or republish).
    private func saveFallbackHost() {
        let trimmed = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = trustedDevicesStore.device(for: device.deviceId)?.fallbackHost ?? ""
        guard trimmed != stored else { fallbackInvalid = false; return }
        if trustedDevicesStore.setFallbackHost(deviceId: device.deviceId, fallbackHost: trimmed) {
            fallbackInvalid = false
        } else {
            fallbackInvalid = true
            fallbackText = stored
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Fallback IP (e.g. Tailscale)")
                .font(.headline)
            FallbackHostField(text: $fallbackText, onCommit: saveFallbackHost)
            if fallbackInvalid {
                Text("That isn't a valid IP address or hostname.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            Button("Forget This Device…", role: .destructive) {
                showForgetConfirmation = true
            }

            Spacer()

            HStack {
                Spacer()
                Button("Done") { saveFallbackHost(); onDone() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340, height: 200)
        .onDisappear { saveFallbackHost() }
        .confirmationDialog(
            "Forget \(device.deviceName)?",
            isPresented: $showForgetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Forget", role: .destructive) { onForget() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This Mac will no longer trust \(device.deviceName). You'll need to pair again to reconnect.")
        }
    }
}
