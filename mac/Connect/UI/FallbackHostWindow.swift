import SwiftUI
import AppKit

/// Hosts a `FallbackHostField` for one device in a plain `NSWindow` — same
/// reason as `PairingWindow`/`DNDSetupWindow`/`ADBPairingWindow`: this app's
/// menu bar content is a `MenuBarExtra(.window)` panel, and any interactive
/// control shown from inside it (a `.sheet`, or a `TextField` embedded
/// directly in a `Menu`) causes the panel to resign key and dismiss itself
/// the instant it's touched — the `TextField` never even gets a chance to
/// take keyboard focus. A normal titled window has no such relationship to
/// the menu-bar panel.
final class FallbackHostWindow: NSWindow {
    init(device: TrustedDevice, trustedDevicesStore: TrustedDevicesStore) {
        let initialFrame = NSRect(x: 0, y: 0, width: 320, height: 120)
        super.init(
            contentRect: initialFrame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "Fallback Host — \(device.deviceName)"
        isReleasedWhenClosed = false

        let hostingView = NSHostingView(
            rootView: FallbackHostWindowContentView(device: device, trustedDevicesStore: trustedDevicesStore, onDone: { [weak self] in
                self?.close()
            })
        )
        contentView = hostingView
        center()
    }
}

private struct FallbackHostWindowContentView: View {
    let device: TrustedDevice
    @ObservedObject var trustedDevicesStore: TrustedDevicesStore
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fallback IP (e.g. Tailscale)")
                .font(.headline)
            FallbackHostField(device: device, trustedDevicesStore: trustedDevicesStore)
            HStack {
                Spacer()
                Button("Done") { onDone() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}
