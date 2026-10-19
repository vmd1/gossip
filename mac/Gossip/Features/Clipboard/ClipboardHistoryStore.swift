import AppKit
import Combine

/// One remembered clipboard text.
struct ClipboardHistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    var text: String
    var date: Date
    var pinned: Bool
    /// `true` if it arrived from a peer rather than being copied here.
    var remote: Bool
}

/// Searchable, pinnable history of clipboard text, kept on this Mac only: never sent to a peer or the relay.
/// On by default (`isEnabled`, which needs no setup); turning it off or `clear()` wipes it. Sensitive and oversized copies are filtered by the caller
/// (`ClipboardSyncManager`) before they get here. Text only for now.
final class ClipboardHistoryStore: ObservableObject {
    static let shared = ClipboardHistoryStore()
    static let enabledKey = "clipboardHistoryEnabled"
    static let maxUnpinned = 100
    static let maxEntryBytes = 100_000

    @Published private(set) var entries: [ClipboardHistoryEntry] = []

    private let url: URL?
    private let defaults: UserDefaults

    init(url: URL? = ClipboardHistoryStore.defaultURL, defaults: UserDefaults = .standard) {
        self.url = url
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

    func togglePin(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].pinned.toggle()
        trim()
        save()
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    /// Wipes everything, pinned included.
    func clear() {
        entries = []
        save()
    }

    /// Pinned first, then newest; filtered by a case-insensitive substring.
    func filtered(_ query: String) -> [ClipboardHistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let matches = q.isEmpty ? entries : entries.filter { $0.text.localizedCaseInsensitiveContains(q) }
        return matches.filter(\.pinned) + matches.filter { !$0.pinned }
    }

    private func trim() {
        var kept = 0
        entries = entries.filter { e in
            if e.pinned { return true }
            kept += 1
            return kept <= Self.maxUnpinned
        }
    }

    private func save() {
        guard let url, let data = try? JSONEncoder().encode(entries) else { return }
        PrivateFile.write(data, to: url)
    }
}
