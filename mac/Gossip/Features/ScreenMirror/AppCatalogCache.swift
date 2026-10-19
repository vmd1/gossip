import AppKit

/// What the Mac remembers about the apps on each phone, so the app picker opens instantly and only what changed is
/// fetched: the app list (package, label and the app's version stamp) and each app's icon. Kept on this Mac only, in
/// Application Support, one folder per phone. A fresh list from the phone replaces the stored one (an app that was
/// uninstalled disappears, along with its icon); an icon is re-fetched only when the app's version stamp changed.
final class AppCatalogCache {
    struct Entry: Codable, Equatable {
        let package: String
        let label: String
        /// The app's last-update time on the phone; a different value means its icon may have changed.
        let version: Int64
    }

    private let root: URL?
    private let fm = FileManager.default

    init(root: URL? = AppCatalogCache.defaultRoot) {
        self.root = root
    }

    static var defaultRoot: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("Gossip/AppCatalog", isDirectory: true)
        PrivateFile.ensureDirectory(dir)
        return dir
    }

    private func folder(_ deviceId: String) -> URL? {
        guard let root, !deviceId.isEmpty, !deviceId.contains("/"), !deviceId.contains("..") else { return nil }
        let dir = root.appendingPathComponent(deviceId, isDirectory: true)
        PrivateFile.ensureDirectory(dir)
        return dir
    }

    private func iconURL(_ deviceId: String, _ package: String, _ version: Int64) -> URL? {
        // Package names are dotted identifiers; refuse anything else so a hostile phone can't pick a path.
        guard package.range(of: #"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$"#, options: .regularExpression) != nil else { return nil }
        return folder(deviceId)?.appendingPathComponent("\(package)@\(version).png")
    }

    // MARK: Apps

    func apps(for deviceId: String) -> [Entry] {
        guard let url = folder(deviceId)?.appendingPathComponent("apps.json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return list
    }

    /// Replaces the stored list with the phone's current one and deletes icons of apps that are gone or whose version
    /// moved on. Returns the packages whose icon is missing and must be fetched. Applying the same list twice changes nothing.
    @discardableResult
    func replaceApps(_ list: [Entry], for deviceId: String) -> [String] {
        guard let dir = folder(deviceId) else { return list.map(\.package) }
        if let data = try? JSONEncoder().encode(list) { PrivateFile.write(data, to: dir.appendingPathComponent("apps.json")) }
        let current = Set(list.map { "\($0.package)@\($0.version).png" })
        for file in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where file.hasSuffix(".png") && !current.contains(file) {
            try? fm.removeItem(at: dir.appendingPathComponent(file))
        }
        return list.filter { icon(for: $0.package, version: $0.version, deviceId: deviceId) == nil }.map(\.package)
    }

    // MARK: Icons

    func icon(for package: String, version: Int64, deviceId: String) -> NSImage? {
        guard let url = iconURL(deviceId, package, version), let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }

    /// Stores an icon for the given app version. Re-storing the same one is a no-op.
    func storeIcon(_ png: Data, package: String, version: Int64, deviceId: String) {
        guard png.count < 64 * 1024, NSImage(data: png) != nil, let url = iconURL(deviceId, package, version),
              !fm.fileExists(atPath: url.path) else { return }
        PrivateFile.write(png, to: url)
    }

    /// `"<package>@<version>"` for every icon already stored, sent with `screen.apps_request` so the phone only sends the rest.
    func haveIcons(for deviceId: String) -> [String] {
        guard let dir = folder(deviceId) else { return [] }
        return ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".png") }.map { String($0.dropLast(4)) }
    }

    func clear(deviceId: String) {
        if let dir = folder(deviceId) { try? fm.removeItem(at: dir) }
    }
}
