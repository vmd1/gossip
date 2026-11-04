import AppKit
import Combine
import CryptoKit

/// One remembered clipboard text.
struct ClipboardHistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    var text: String
    var date: Date
    var pinned: Bool
    /// `true` if it arrived from a peer rather than being copied here.
    var remote: Bool
    /// For an image entry: the PNG's file name in the history's image folder (`text` is then a label like "Image 800×600").
    var imageFile: String? = nil
    /// For an image entry: SHA-256 of the PNG, so copying the same image again moves it to the top instead of adding it.
    var digest: String? = nil

    var isImage: Bool { imageFile != nil }
}

/// Searchable, pinnable history of clipboard text, kept on this Mac only: never sent to a peer or the relay.
/// On by default (`isEnabled`, which needs no setup); turning it off or `clear()` wipes it. Sensitive and oversized copies are filtered by the caller
/// (`ClipboardSyncManager`) before they get here. Text and images; an image is a PNG file in a private folder next to the history.
final class ClipboardHistoryStore: ObservableObject {
    static let shared = ClipboardHistoryStore()
    static let enabledKey = "clipboardHistoryEnabled"
    static let maxUnpinned = 100
    static let maxEntryBytes = 100_000
    static let maxImageBytes = 4 << 20

    @Published private(set) var entries: [ClipboardHistoryEntry] = []

    private let url: URL?
    private let imageDirectory: URL?
    private let defaults: UserDefaults

    init(url: URL? = ClipboardHistoryStore.defaultURL, imageDirectory: URL? = ClipboardHistoryStore.defaultImageDirectory,
         defaults: UserDefaults = .standard) {
        self.url = url
        self.imageDirectory = imageDirectory
        self.defaults = defaults
        if let url, let data = try? Data(contentsOf: url),
           let loaded = try? JSONDecoder().decode([ClipboardHistoryEntry].self, from: data) {
            entries = loaded
        }
    }

    static var defaultURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("Gossip", isDirectory: true)
        PrivateFile.ensureDirectory(dir)
        return dir.appendingPathComponent("clipboard-history.json")
    }

    static var defaultImageDirectory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("Gossip", isDirectory: true).appendingPathComponent("clipboard-images", isDirectory: true)
        PrivateFile.ensureDirectory(dir)
        return dir
    }

    var isEnabled: Bool {
        get { (defaults.object(forKey: Self.enabledKey) as? Bool) ?? true }
        set {
            defaults.set(newValue, forKey: Self.enabledKey)
            if !newValue { clear() }
            objectWillChange.send()
        }
    }

    /// Records a copy. Re-copying existing text moves it to the top (keeping its pin); idempotent for the same value.
    func record(_ text: String, remote: Bool, now: Date = Date()) {
        guard isEnabled, !text.isEmpty, text.utf8.count <= Self.maxEntryBytes,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let i = entries.firstIndex(where: { $0.text == text }) {
            var e = entries.remove(at: i)
            e.date = now
            entries.insert(e, at: 0)
        } else {
            entries.insert(ClipboardHistoryEntry(id: UUID(), text: text, date: now, pinned: false, remote: remote), at: 0)
        }
        trim()
        save()
    }

    /// Records a copied image (PNG bytes, already checked as a reasonable PNG by the caller). Copying the same image again
    /// moves it to the top; idempotent for the same bytes. An image over `maxImageBytes`, or with nowhere to store it, is skipped.
    func recordImage(_ png: Data, width: Int, height: Int, remote: Bool, now: Date = Date()) {
        guard isEnabled, !png.isEmpty, png.count <= Self.maxImageBytes, let imageDirectory else { return }
        let digest = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        if let i = entries.firstIndex(where: { $0.digest == digest }) {
            var e = entries.remove(at: i)
            e.date = now
            entries.insert(e, at: 0)
        } else {
            PrivateFile.ensureDirectory(imageDirectory)
            let file = UUID().uuidString + ".png"
            guard PrivateFile.write(png, to: imageDirectory.appendingPathComponent(file)) else { return }
            entries.insert(ClipboardHistoryEntry(id: UUID(), text: "Image \(width)×\(height)", date: now, pinned: false, remote: remote,
                                                 imageFile: file, digest: digest), at: 0)
        }
        trim()
        save()
    }

    /// The PNG bytes of an image entry.
    func imageData(for entry: ClipboardHistoryEntry) -> Data? {
        guard let file = entry.imageFile, let imageDirectory else { return nil }
        return try? Data(contentsOf: imageDirectory.appendingPathComponent(file))
    }

    func togglePin(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].pinned.toggle()
        trim()
        save()
    }

    func remove(_ id: UUID) {
        deleteImageFiles(of: entries.filter { $0.id == id })
        entries.removeAll { $0.id == id }
        save()
    }

    /// Wipes everything, pinned included (and every stored image file).
    func clear() {
        deleteImageFiles(of: entries)
        entries = []
        save()
    }

    private func deleteImageFiles(of removed: [ClipboardHistoryEntry]) {
        guard let imageDirectory else { return }
        for file in removed.compactMap(\.imageFile) {
            try? FileManager.default.removeItem(at: imageDirectory.appendingPathComponent(file))
        }
    }

    /// Pinned first, then newest; filtered by a case-insensitive substring.
    func filtered(_ query: String) -> [ClipboardHistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let matches = q.isEmpty ? entries : entries.filter { $0.text.localizedCaseInsensitiveContains(q) }
        return matches.filter(\.pinned) + matches.filter { !$0.pinned }
    }

    private func trim() {
        var kept = 0
        var dropped: [ClipboardHistoryEntry] = []
        entries = entries.filter { e in
            if e.pinned { return true }
            kept += 1
            if kept <= Self.maxUnpinned { return true }
            dropped.append(e)
            return false
        }
        deleteImageFiles(of: dropped)
    }

    private func save() {
        guard let url, let data = try? JSONEncoder().encode(entries) else { return }
        PrivateFile.write(data, to: url)
    }
}
