import Foundation
import AppKit

/// User preference for keeping the launcher installed (on by default).
enum LauncherPreference {
    private static let key = "deviceMirroringLauncher.autoInstall"
    static var autoInstall: Bool {
        get { (UserDefaults.standard.object(forKey: key) as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// Gossip's side of keeping the launcher installed: decide what is needed (read-only) and, if anything,
/// start the embedded launcher, which copies itself out (see the launcher's `main.swift`). Gossip is
/// sandboxed — it can't create launchable files or pass arguments — so it only starts the app.
enum LauncherSetup {
    /// Installs or repairs the launcher if it is missing, outdated or quarantined. Fire-and-forget.
    static func ensureInstalled(installer: LauncherInstaller = LauncherInstaller()) {
        switch installer.status() {
        case .missing, .outdated, .quarantined: break
        case .current, .notApplicable: return
        }
        guard let embedded = installer.embeddedLauncherURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: embedded, configuration: configuration) { _, error in
            if let error { BLEProximityMonitor.debugLog("couldn't start the Device Mirroring installer: \(error)") }
        }
    }
}
