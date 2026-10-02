import AppKit

/// "Device Mirroring": a tiny app that asks the (possibly not yet running) Gossip app to open its Device
/// Mirroring window, then quits. The live device list and the mirror session belong to the Gossip process,
/// so this app deliberately does nothing but hand over.
///
/// It has a second job, chosen purely by *where it is running*: the copy embedded in
/// `Gossip.app/Contents/SharedSupport` — which nobody opens by hand — instead copies itself out next to
/// Gossip (`LauncherInstaller`), then quits. Gossip is sandboxed and can't create launchable files, so it
/// just starts that embedded copy and lets it do the install; no flags or extra URL schemes are involved.
final class LauncherDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let gossip = enclosingGossipApp() {
            let installer = LauncherInstaller(embeddedLauncherURL: Bundle.main.bundleURL, gossipURL: gossip)
            NSLog("Device Mirroring: install -> \(installer.install())")
            NSApp.terminate(nil)
        } else {
            openGossipDeviceMirroring()
        }
    }

    /// `…/Gossip.app` if this is the copy embedded in it (`…/Gossip.app/Contents/SharedSupport/Device Mirroring.app`).
    private func enclosingGossipApp() -> URL? {
        let bundle = Bundle.main.bundleURL
        let shared = bundle.deletingLastPathComponent()
        guard shared.lastPathComponent == "SharedSupport" else { return nil }
        let gossip = shared.deletingLastPathComponent().deletingLastPathComponent()
        return gossip.pathExtension == "app" ? gossip : nil
    }

    private func openGossipDeviceMirroring() {
        guard let gossipURL = GossipLocator.locate(
            launcherURL: Bundle.main.bundleURL,
            lookUpByBundleIdentifier: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        ) else {
            let alert = NSAlert()
            alert.messageText = "Gossip isn't installed"
            alert.informativeText = "Device Mirroring needs the Gossip app. Install Gossip (and keep it in the same folder as this app), then try again."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // Open the URL *with* Gossip explicitly rather than letting LaunchServices pick a handler for the
        // scheme — this also starts Gossip if it isn't running yet.
        NSWorkspace.shared.open([URL(string: "connect://mirror")!], withApplicationAt: gossipURL, configuration: configuration) { _, error in
            if let error { NSLog("Device Mirroring: couldn't open Gossip: \(error)") }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

let app = NSApplication.shared
let delegate = LauncherDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
