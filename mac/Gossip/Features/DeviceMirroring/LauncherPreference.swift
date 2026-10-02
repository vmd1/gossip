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

/// Keeps the launcher installed. Gossip is no longer sandboxed, so it copies the embedded launcher out
/// itself (`LauncherInstaller.install()`); that also clears any quarantine flag the copy inherited.
enum LauncherSetup {
    /// Installs or repairs the launcher if it is missing, outdated or quarantined. Fire-and-forget.
    static func ensureInstalled(installer: LauncherInstaller = LauncherInstaller()) {
        switch installer.status() {
        case .missing, .outdated, .quarantined: break
        case .current, .notApplicable: return
        }
        DispatchQueue.global(qos: .utility).async {
            NSLog("Gossip: Device Mirroring launcher install -> \(installer.install())")
        }
    }
}
