import Foundation

/// One person from a phone's contacts.
struct PhoneContact: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let numbers: [String]
}

/// The phones' contacts as last synced, kept on this Mac only (Application Support, one file per phone) so names are
/// available the moment the Messages window opens. The phone owns the truth: a newer list replaces the stored one.
final class ContactsCache {
    struct Stored: Codable { var digest: String; var contacts: [PhoneContact] }

    private let root: URL?

    init(root: URL? = ContactsCache.defaultRoot) { self.root = root }

    static var defaultRoot: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("Gossip/Contacts", isDirectory: true)
        PrivateFile.ensureDirectory(dir)
        return dir
    }

    private func file(_ deviceId: String) -> URL? {
        guard let root, !deviceId.isEmpty, !deviceId.contains("/"), !deviceId.contains("..") else { return nil }
        return root.appendingPathComponent("\(deviceId).json")
    }

    func load(_ deviceId: String) -> Stored? {
        guard let url = file(deviceId), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    func save(_ stored: Stored, for deviceId: String) {
        guard let url = file(deviceId), let data = try? JSONEncoder().encode(stored) else { return }
        PrivateFile.write(data, to: url)
    }

    func clear(_ deviceId: String) { if let url = file(deviceId) { try? FileManager.default.removeItem(at: url) } }
}

/// Collects the pages of one contacts list; complete once every page of the same digest has arrived. Receiving a page twice
/// changes nothing, and a page of a different digest restarts collection (the phone's list changed mid-transfer).
struct ContactsAssembler {
    private var digest: String?
    private var pages: [Int: [PhoneContact]] = [:]
    private var total = 0

    /// Returns the full list once complete.
    mutating func add(digest: String, page: Int, pages total: Int, contacts: [PhoneContact]) -> [PhoneContact]? {
        guard total >= 1, total <= 40, page >= 0, page < total else { return nil }
        if self.digest != digest || self.total != total { self.digest = digest; self.total = total; pages = [:] }
        pages[page] = contacts
        guard pages.count == total else { return nil }
        let all = (0..<total).flatMap { pages[$0] ?? [] }
        self.digest = nil; pages = [:]
        return all
    }
}

enum ContactMatching {
    /// Last ten digits, so `+44 7700 900123` and `07700 900123` compare equal; names/short codes compare as lowercase text.
    static func normalize(_ address: String) -> String {
        let digits = address.filter(\.isNumber)
        return digits.count >= 7 ? String(digits.suffix(10)) : address.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Contacts whose name contains `query` (any word start first), or whose number contains the query's digits.
    static func suggestions(for query: String, in contacts: [PhoneContact], limit: Int = 6) -> [(contact: PhoneContact, number: String)] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let digits = q.filter(\.isNumber)
        var starts: [(PhoneContact, String)] = [], contains: [(PhoneContact, String)] = []
        for c in contacts {
            let n = c.name.lowercased(), lq = q.lowercased()
            let hit: Int  // 0 = word-start name match, 1 = name contains, 2 = number match, -1 = none
            if n.hasPrefix(lq) || n.split(separator: " ").contains(where: { $0.hasPrefix(lq) }) { hit = 0 }
            else if n.contains(lq) { hit = 1 }
            else if digits.count >= 3, c.numbers.contains(where: { $0.filter(\.isNumber).contains(digits) }) { hit = 2 }
            else { hit = -1 }
            guard hit >= 0, let number = (hit == 2 ? c.numbers.first { $0.filter(\.isNumber).contains(digits) } : c.numbers.first) else { continue }
            if hit == 0 { starts.append((c, number)) } else { contains.append((c, number)) }
        }
        return Array((starts + contains).prefix(limit)).map { (contact: $0.0, number: $0.1) }
    }
}
