import Foundation
import CryptoKit

/// Keeps the "Device Mirroring" launcher app (embedded inside `Gossip.app`) installed next to Gossip so it
/// shows up in Spotlight and Launchpad as its own app. An app nested in another app's bundle isn't indexed
/// individually, so it is copied out — into `/Applications` or `~/Applications`, whichever Gossip lives in.
///
/// **Who does the copying matters.** Gossip is sandboxed, and every file a sandboxed process creates is
/// quarantined as "created by an AppSandbox", which Gatekeeper refuses to open — and a sandboxed process
/// cannot clear that flag (verified: the flags stay on). So Gossip only *reads* this state (`status()`) and
/// starts the embedded, non-sandboxed launcher, which copies itself out and
/// creates ordinary files and clears any quarantine. This file is compiled into both targets.
///
/// Never touches an app it didn't put there: it only replaces a bundle whose identifier is the launcher's.
struct LauncherInstaller {
    static let launcherName = "Device Mirroring.app"
    static let launcherBundleIdentifier = "dev.vmd1.gossip.DeviceMirroring"

    enum Outcome: Equatable {
        case installed
        case updated
        case upToDate
        case notApplicable(String)
        case failed(String)
    }

    /// What `install()` would have to do — read-only, so it is safe to call from the sandboxed Gossip.
    enum Status: Equatable {
        case notApplicable(String)
        case missing
        /// Installed, but the embedded launcher is newer.
        case outdated
        /// Installed and current, but flagged quarantined so Gatekeeper blocks it (e.g. an earlier copy
        /// made by the sandboxed app).
        case quarantined
        case current
    }

    /// The launcher inside Gossip's bundle (`Contents/SharedSupport`), or nil if this build has none.
    let embeddedLauncherURL: URL?
    /// Where the running Gossip lives.
    let gossipURL: URL
    /// Folders a launcher may be installed into; Gossip must itself live in one of them.
    let allowedDirectories: [URL]
    let fileManager: FileManager

    init(
        embeddedLauncherURL: URL? = Bundle.main.sharedSupportURL?.appendingPathComponent(LauncherInstaller.launcherName),
        gossipURL: URL = Bundle.main.bundleURL,
        allowedDirectories: [URL] = LauncherInstaller.defaultAllowedDirectories(),
        fileManager: FileManager = .default
    ) {
        self.embeddedLauncherURL = embeddedLauncherURL
        self.gossipURL = gossipURL
        self.allowedDirectories = allowedDirectories
        self.fileManager = fileManager
    }

    /// `/Applications` and the *real* `~/Applications` (a sandboxed app's `NSHomeDirectory()` is its
    /// container, so the account's home comes from the password database instead).
    static func defaultAllowedDirectories() -> [URL] {
        var dirs = [URL(fileURLWithPath: "/Applications", isDirectory: true)]
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            dirs.append(URL(fileURLWithPath: String(cString: home), isDirectory: true).appendingPathComponent("Applications", isDirectory: true))
        }
        return dirs
    }

    /// The folder to install into: the one Gossip itself lives in, if it is an allowed one.
    var destinationDirectory: URL? {
        let gossipDir = gossipURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        return allowedDirectories.first { $0.standardizedFileURL.resolvingSymlinksInPath() == gossipDir }
    }

    var installedLauncherURL: URL? {
        destinationDirectory?.appendingPathComponent(Self.launcherName)
    }

    /// Whether the launcher is currently installed (and is ours).
    var isInstalled: Bool {
        guard let url = installedLauncherURL else { return false }
        return Self.bundleIdentifier(of: url) == Self.launcherBundleIdentifier
    }

    func status() -> Status {
        guard let embedded = embeddedLauncherURL, fileManager.fileExists(atPath: embedded.path) else {
            return .notApplicable("This build of Gossip doesn't include the Device Mirroring app.")
        }
        guard let destination = installedLauncherURL else {
            return .notApplicable("Move Gossip into your Applications folder to add Device Mirroring.")
        }
        guard fileManager.fileExists(atPath: destination.path) else { return .missing }
        guard Self.bundleIdentifier(of: destination) == Self.launcherBundleIdentifier else {
            return .notApplicable("Another app named “Device Mirroring” is already in \(destination.deletingLastPathComponent().path).")
        }
        if Self.fingerprint(of: destination) != Self.fingerprint(of: embedded) { return .outdated }
        return Self.hasQuarantine(destination, fileManager: fileManager) ? .quarantined : .current
    }

    /// Copies the embedded launcher out next to Gossip, or refreshes it if the embedded one changed.
    /// **Must run in a non-sandboxed process** (see the type's doc).
    @discardableResult
    func install() -> Outcome {
        switch status() {
        case .notApplicable(let reason):
            return .notApplicable(reason)
        case .current:
            return .upToDate
        case .quarantined:
            guard let destination = installedLauncherURL else { return .failed("no destination") }
            Self.stripQuarantine(from: destination, fileManager: fileManager)
            return Self.hasQuarantine(destination, fileManager: fileManager) ? .failed("couldn't clear the quarantine flag") : .updated
        case .missing, .outdated:
            guard let embedded = embeddedLauncherURL, let destination = installedLauncherURL else { return .failed("no destination") }
            let existed = fileManager.fileExists(atPath: destination.path)
            do {
                if existed { try fileManager.removeItem(at: destination) }
                try fileManager.copyItem(at: embedded, to: destination)
                Self.stripQuarantine(from: destination, fileManager: fileManager)
                return existed ? .updated : .installed
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Helpers

    static func bundleIdentifier(of appURL: URL) -> String? {
        let plist = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return dict["CFBundleIdentifier"] as? String
    }

    /// SHA-256 of the app's main executable. The version number never changes between builds, so the
    /// executable's contents are what tell "same launcher" from "newer launcher".
    static func fingerprint(of appURL: URL) -> String? {
        let macOS = appURL.appendingPathComponent("Contents/MacOS")
        guard let name = (try? FileManager.default.contentsOfDirectory(atPath: macOS.path))?.first,
              let data = try? Data(contentsOf: macOS.appendingPathComponent(name))
        else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hasQuarantine(_ appURL: URL, fileManager: FileManager = .default) -> Bool {
        func quarantined(_ path: String) -> Bool { getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0 }
        if quarantined(appURL.path) { return true }
        guard let enumerator = fileManager.enumerator(atPath: appURL.path) else { return false }
        for case let relative as String in enumerator where quarantined(appURL.appendingPathComponent(relative).path) { return true }
        return false
    }

    /// Clears the quarantine flag from the whole bundle (only works from a non-sandboxed process). Files a
    /// sandboxed app creates are quarantined, which would make Gatekeeper block the launcher the
    /// first time it is opened even though Gossip itself was already approved.
    static func stripQuarantine(from appURL: URL, fileManager: FileManager = .default) {
        let name = "com.apple.quarantine"
        removexattr(appURL.path, name, XATTR_NOFOLLOW)
        guard let enumerator = fileManager.enumerator(atPath: appURL.path) else { return }
        for case let relative as String in enumerator {
            removexattr(appURL.appendingPathComponent(relative).path, name, XATTR_NOFOLLOW)
        }
    }
}
