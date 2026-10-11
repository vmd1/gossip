import Foundation

/// What this Mac believes about the notifications mirrored from phones, kept apart from `UNUserNotificationCenter` so
/// the reconciliation rules can be tested. Thread-safe.
///
/// Three things can drift between a phone and this Mac, and each has a repair:
/// - a `notification.removed` lost to a disconnect: the phone's periodic `notification.sync` lists what it still
///   mirrors, and anything else shown here (for more than `syncGrace`) is removed;
/// - a `notification.posted` that lands after its own removal (it waits on the icon decode): `removedAt` remembers the
///   removal's timestamp and a post that is not later than it is dropped;
/// - a `notification.dismiss` (the user cleared it here) lost on the way to the phone: `dismissedHere` remembers it and
///   a sync that still lists the id triggers another dismiss.
final class NotificationMirrorBook {
    static let maxTracked = 512
    static let syncGrace: TimeInterval = 10
    static let dismissRetention: TimeInterval = 600

    private let lock = NSLock()
    private var shown: [String: Date] = [:]
    private var dismissedHere: [String: Date] = [:]
    private var removedAt: [String: Int64] = [:]

    var shownIdentifiers: Set<String> { lock.lock(); defer { lock.unlock() }; return Set(shown.keys) }
    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return shown.isEmpty }

    func recordShown(_ identifier: String, at date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        shown[identifier] = date
    }

    func forget(_ identifier: String) {
        lock.lock(); defer { lock.unlock() }
        shown.removeValue(forKey: identifier)
    }

    /// The phone removed it. `ts` is the removal envelope's timestamp (the phone's clock).
    func recordRemoval(_ identifier: String, at ts: Int64) {
        lock.lock(); defer { lock.unlock() }
        removedAt[identifier] = max(removedAt[identifier] ?? Int64.min, ts)
        shown.removeValue(forKey: identifier)
        if removedAt.count > Self.maxTracked {
            for (key, _) in removedAt.sorted(by: { $0.value < $1.value }).prefix(removedAt.count - Self.maxTracked) {
                removedAt.removeValue(forKey: key)
            }
        }
    }

    /// Whether a `notification.posted` (its own timestamp is the phone's post time) is older than a removal already seen.
    func isStale(_ identifier: String, postedAt: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let removed = removedAt[identifier] else { return false }
        return postedAt <= removed
    }

    /// The user dismissed it here.
    func recordDismissedHere(_ identifier: String, at date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        shown.removeValue(forKey: identifier)
        dismissedHere[identifier] = date
        if dismissedHere.count > Self.maxTracked {
            for (key, _) in dismissedHere.sorted(by: { $0.value < $1.value }).prefix(dismissedHere.count - Self.maxTracked) {
                dismissedHere.removeValue(forKey: key)
            }
        }
    }

    struct SyncOutcome: Equatable {
        /// Shown here but no longer on the phone: remove them.
        var remove: [String]
        /// The phone still lists them although the user dismissed them here: dismiss again.
        var redismiss: [String]
    }

    /// Applies a `notification.sync` from `sender`. `liveIdentifiers` are the phone's ids already turned into local
    /// identifiers; `owns` says whether a local identifier belongs to `sender`. Idempotent.
    func applySync(liveIdentifiers: Set<String>, owns: (String) -> Bool, now: Date = Date()) -> SyncOutcome {
        lock.lock(); defer { lock.unlock() }
        let gone = shown.filter { identifier, postedAt in
            owns(identifier) && !liveIdentifiers.contains(identifier) && now.timeIntervalSince(postedAt) > Self.syncGrace
        }.keys
        for identifier in gone { shown.removeValue(forKey: identifier) }
        dismissedHere = dismissedHere.filter { now.timeIntervalSince($0.value) < Self.dismissRetention }
        let again = liveIdentifiers.filter { dismissedHere[$0] != nil }
        return SyncOutcome(remove: Array(gone).sorted(), redismiss: Array(again).sorted())
    }
}
