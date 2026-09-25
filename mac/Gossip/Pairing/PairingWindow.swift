import SwiftUI
import AppKit

/// Hosts `PairingSheetView` in a plain, ordinary `NSWindow` — deliberately
/// NOT a SwiftUI `.sheet` presented from the menu-bar dropdown. Presenting a
/// `.sheet` from a `.menuBarExtraStyle(.window)` content view causes that
/// borderless panel to resign key status and auto-dismiss itself (taking the
/// sheet down with it) the moment the user interacts with anything inside
/// it, which made pairing impossible: the QR code / confirm UI vanished
/// before it could be used. A normal titled window has no such relationship
/// to the menu-bar panel and behaves like any other Mac window.
final class PairingWindow: NSWindow {
    init(pairingViewModel: PairingViewModel) {
        let initialFrame = NSRect(x: 0, y: 0, width: 320, height: 360)
        super.init(
            contentRect: initialFrame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "Pair New Device"
        isReleasedWhenClosed = false

        let hostingView = NSHostingView(
            rootView: PairingSheetView(pairingViewModel: pairingViewModel, onDismiss: { [weak self] in
                self?.close()
            })
        )
        contentView = hostingView
        center()
    }
}
