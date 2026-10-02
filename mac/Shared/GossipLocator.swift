import Foundation

/// Finds the Gossip app for the "Device Mirroring" launcher. Compiled into both the Gossip app (so it
/// can be unit-tested) and the launcher.
///
/// Prefers a `Gossip.app` sitting in the **same folder** as the launcher: the launcher is copied
/// next to Gossip (see `LauncherInstaller`), and going by the neighbouring copy avoids asking
/// LaunchServices, which can hand back a stray build-folder or old download instead. Falls back to
/// looking Gossip up by bundle identifier.
enum GossipLocator {
    static let gossipBundleIdentifier = "dev.vmd1.gossip.Gossip"
    static let gossipAppName = "Gossip.app"

    static func locate(
        launcherURL: URL,
        fileManager: FileManager = .default,
        lookUpByBundleIdentifier: (String) -> URL? = { _ in nil }
    ) -> URL? {
        let sibling = launcherURL.deletingLastPathComponent().appendingPathComponent(gossipAppName)
        if fileManager.fileExists(atPath: sibling.path) { return sibling }
        return lookUpByBundleIdentifier(gossipBundleIdentifier)
    }
}
