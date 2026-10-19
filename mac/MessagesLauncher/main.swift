import AppKit

/// "Gossip Messages": a tiny app that asks the (possibly not yet running) Gossip app to open its Messages window,
/// then quits. The conversations and the connection to the phone belong to the Gossip process, so this app
/// deliberately does nothing but hand over. (Gossip copies this app out next to itself, see `LauncherInstaller`.)
final class LauncherDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        openGossipMessages()
    }

    private func openGossipMessages() {
        guard let gossipURL = GossipLocator.locate(
            launcherURL: Bundle.main.bundleURL,
            lookUpByBundleIdentifier: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        ) else {
            let alert = NSAlert()
            alert.messageText = "Gossip isn't installed"
            alert.informativeText = "Gossip Messages needs the Gossip app. Install Gossip (and keep it in the same folder as this app), then try again."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([URL(string: "connect://messages")!], withApplicationAt: gossipURL, configuration: configuration) { _, error in
            if let error { NSLog("Gossip Messages: couldn't open Gossip: \(error)") }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

let app = NSApplication.shared
let delegate = LauncherDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
