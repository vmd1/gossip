import SwiftUI
import AppKit

/// Hosts `DNDSetupView` in a plain `NSWindow` for the same reason
/// `PairingWindow` does — see its doc comment. `.sheet` doesn't work
/// reliably from a `.menuBarExtraStyle(.window)` content view.
final class DNDSetupWindow: NSWindow {
    init() {
        let initialFrame = NSRect(x: 0, y: 0, width: 420, height: 520)
        super.init(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        title = "Do Not Disturb Sync Setup"
        isReleasedWhenClosed = false

        let hostingView = NSHostingView(
            rootView: DNDSetupView(onDismiss: { [weak self] in
                self?.close()
            })
        )
        contentView = hostingView
        center()
    }
}
