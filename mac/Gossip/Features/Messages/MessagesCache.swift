import Foundation

/// The conversation lists and recent messages as last received from each phone, kept on this Mac only (Application Support,
/// owner-only files) so the Messages window shows something the moment it opens instead of waiting on the phone. The phone owns
/// the truth: every fresh answer replaces what is stored, and a cache that is missing or unreadable is simply empty.
final class MessagesCache {
    private let root: URL?
    /// Messages kept per conversation: the newest ones, enough to fill the window.
    static let messagesPerThread = 100

    init(root: URL? = MessagesCache.defaultRoot) { self.root = root }

    static var defaultRoot: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("Gossip/Messages", isDirectory: true)
        PrivateFile.ensureDirectory(dir)
        return dir
    }

    private func file(_ name: String) -> URL? {
        guard let root, !name.isEmpty, !name.contains("/"), !name.contains("..") else { return nil }
        return root.appendingPathComponent(name)
    }

    /// File-name-safe form of an id that may carry other characters (a phone's thread id).
    private static func safe(_ id: String) -> String {
        String(id.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? Character($0) : "_" })
    }

    func loadThreads(_ phoneId: String) -> [MessageThread] {
        guard let url = file("threads-\(Self.safe(phoneId)).json"), let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([MessageThread].self, from: data)) ?? []
    }

    func saveThreads(_ threads: [MessageThread], for phoneId: String) {
        guard let url = file("threads-\(Self.safe(phoneId)).json"), let data = try? JSONEncoder().encode(threads) else { return }
        PrivateFile.write(data, to: url)
    }

    func loadMessages(_ threadId: String) -> [ChatMessage] {
        guard let url = file("history-\(Self.safe(threadId)).json"), let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ChatMessage].self, from: data)) ?? []
    }

    /// Only messages the phone confirmed: unsent and failed ones are local state, not history.
    func saveMessages(_ messages: [ChatMessage], for threadId: String) {
        let kept = messages.filter { !$0.sending && !$0.failed }.suffix(Self.messagesPerThread)
        guard let url = file("history-\(Self.safe(threadId)).json"), let data = try? JSONEncoder().encode(Array(kept)) else { return }
        PrivateFile.write(data, to: url)
    }
}
