import Foundation
import CryptoKit

/// Keeps the "Device Mirroring" launcher app (embedded inside `Gossip.app`) installed next to Gossip so it
/// shows up in Spotlight and Launchpad as its own app. An app nested in another app's bundle isn't indexed
/// individually, so it is copied out — into `/Applications` or `~/Applications`, whichever Gossip lives in.
///
/// Gossip is not sandboxed, so it does the copy itself and clears any quarantine flag the copy inherited
/// (e.g. when Gossip was downloaded) so Gatekeeper doesn't block the launcher on first open.
/// This file is compiled into both targets.
///
/// Never touches an app it didn't put there: it only replaces a bundle whose identifier is the launcher's. The
/// replacement is atomic, and "up to date" means the whole bundle matches the embedded one, not just its executable.
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

    /// What `install()` would have to do — read-only.
    enum Status: Equatable {
        case notApplicable(String)
        case missing
        /// Installed, but the embedded launcher is newer.
        case outdated
        /// Installed and current, but flagged quarantined so Gatekeeper blocks it (e.g. an earlier copy
        /// made by the old sandboxed Gossip).
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

    /// `/Applications` and the account's `~/Applications` (home taken from the password database).
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
                // Copy next to the destination first, then swap it in atomically, so a failure part way
                // never leaves a half-copied launcher (or none) in place of a working one.
                let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).staging.app")
                defer { try? fileManager.removeItem(at: staging) }
                try fileManager.copyItem(at: embedded, to: staging)
                Self.stripQuarantine(from: staging, fileManager: fileManager)
                if existed {
                    _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
                } else {
                    try fileManager.moveItem(at: staging, to: destination)
                }
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

    /// SHA-256 over every file in the bundle (relative paths and contents, in a fixed order, symlinks by
    /// target) — not just the executable — so a launcher whose resources, Info.plist or signature were
    /// altered no longer reads as "current". Extended attributes are ignored, so the quarantine flag
    /// doesn't change it.
    static func fingerprint(of appURL: URL) -> String? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: appURL.path) else { return nil }
        let paths = enumerator.compactMap { $0 as? String }.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        guard !paths.isEmpty else { return nil }
        var hasher = SHA256()
        for relative in paths {
            let url = appURL.appendingPathComponent(relative)
            hasher.update(data: Data(relative.utf8))
            if let target = try? fm.destinationOfSymbolicLink(atPath: url.path) {
                hasher.update(data: Data("->\(target)".utf8))
            } else {
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
                if isDirectory.boolValue { hasher.update(data: Data("/".utf8)); continue }
                guard let data = try? Data(contentsOf: url) else { return nil }
                hasher.update(data: data)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func hasQuarantine(_ appURL: URL, fileManager: FileManager = .default) -> Bool {
        func quarantined(_ path: String) -> Bool { getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0 }
        if quarantined(appURL.path) { return true }
        guard let enumerator = fileManager.enumerator(atPath: appURL.path) else { return false }
        for case let relative as String in enumerator where quarantined(appURL.appendingPathComponent(relative).path) { return true }
        return false
    }

    /// Clears the quarantine flag from the whole bundle . A copy made from a quarantined
    /// (downloaded) Gossip can carry the flag, which would make Gatekeeper block the launcher the first
    /// time it is opened.
    static func stripQuarantine(from appURL: URL, fileManager: FileManager = .default) {
        let name = "com.apple.quarantine"
        removexattr(appURL.path, name, XATTR_NOFOLLOW)
        guard let enumerator = fileManager.enumerator(atPath: appURL.path) else { return }
        for case let relative as String in enumerator {
            removexattr(appURL.appendingPathComponent(relative).path, name, XATTR_NOFOLLOW)
        }
    }
}
