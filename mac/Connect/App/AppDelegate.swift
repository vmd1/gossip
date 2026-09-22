import AppKit

/// Lifecycle hooks that don't fit naturally into the SwiftUI `App`/`Scene`
/// structure (e.g. ensuring the app never shows a Dock icon even if launched
/// in a way that would otherwise trigger one).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
