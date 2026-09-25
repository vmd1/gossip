import AppKit

/// Lifecycle hooks that don't fit naturally into the SwiftUI `App`/`Scene`
/// structure (e.g. ensuring the app never shows a Dock icon even if launched
/// in a way that would otherwise trigger one).
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `ConnectApp` once its dependencies (in particular `DNDSyncManager`) exist,
    /// since app delegate creation (`@NSApplicationDelegateAdaptor`) and
    /// `ConnectApp.init()` are two separate initialization paths.
    var onOpenURLs: (([URL]) -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Handles `connect://...` URLs (see `DNDSyncManager`), e.g. opened by the
    /// Shortcuts "When Focus is turned on/off" automations. Connect is a menu-bar app
    /// with no `WindowGroup` scene, so there's no SwiftUI `onOpenURL` to receive these
    /// directly — this app-delegate hook is the standard AppKit equivalent.
    func application(_ application: NSApplication, open urls: [URL]) {
        onOpenURLs?(urls)
    }
}
