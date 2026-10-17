import Foundation
import GossipCoreKit

/// Bridges macOS Focus/Do Not Disturb state with the paired Android device.
///
/// macOS has no public API to read or set Focus/DND state, so this is bridged through
/// the Shortcuts app in both directions, requiring one-time manual setup by the user
/// (see `DNDSetupView` for the exact Shortcuts to create — this is the documented,
/// deliberate design; it cannot be auto-provisioned).
///
/// **Reporting (Mac -> Android)**: the app registers the `connect://` URL scheme (see
/// `Info.plist` `CFBundleURLTypes` and `AppDelegate.application(_:open:)`). Two
/// Shortcuts *automations* the user creates during onboarding — "When Focus is turned
/// on" / "When Focus is turned off" — open `connect://dnd?state=on` /
/// `connect://dnd?state=off`, which this class turns into a `dnd.update` envelope sent
/// to the paired device.
///
/// **Control (Android -> Mac)**: registers a `MessageRouter` handler for `dnd.set`. On
/// receipt, shells out to `shortcuts run "Connect Turn On DND"` /
/// `shortcuts run "Connect Turn Off DND"` — two ordinary Shortcuts (built from
/// Shortcuts' own Focus actions) the user creates during onboarding with those exact
/// names.
///
/// **Auto-reconciliation**: each device publishes its DND state as the `dnd.state` state
/// slot (see `docs/plans/state-sync.md`), and a peer's state that disagrees with
/// `expectedState` is applied locally (same as `dnd.set`), so toggling either device's
/// Focus/DND mirrors onto the other. The decisions (echo suppression, cooldown, the
/// first-contact OR-merge) are the core's `Dnd`; this class only talks to the OS. This mirroring, plus running a Shortcut to apply a peer's request,
/// creates a feedback loop risk: running "Connect Turn On/Off DND" changes this Mac's
/// Focus, which itself fires the "When Focus is turned on/off" automation, delivering
/// another `connect://dnd` call for the *same* change we just made. `expectedState`
/// dedupes that (same convention as `clipboard.update`, see `schema/message-types.md`),
/// and `reconcileCooldown` is a belt-and-suspenders guard against that automation's
/// delivery timing racing the in-memory state update.
final class DNDSyncManager {
    private weak var transportManager: TransportManager?
    private let identity: IdentityKeyStore
    /// The decision logic, shared with every platform (`desktop/core/src/features/dnd.rs`).
    private let logic: GossipCoreKit.Dnd
    private let lock = NSLock()
    private let shortcutQueue = DispatchQueue(label: "dev.vmd1.gossip.dnd.shortcuts")
    private let shortcutLock = NSLock()
    private var shortcutsInFlight = 0
    private var lastShortcutFinishedMs: Int64 = 0
    /// How long after our Shortcut exits a Focus-change callback is still treated as its echo.
    private static let echoSettleMs: Int64 = 5_000

    /// The DND/Focus state this Mac is believed to be in. Persisted (not just in-memory): macOS has no API to *read* current
    /// Focus state, so on a fresh launch this is the only way this Mac has any idea what it's in. Still only a best-effort
    /// belief: if the user changes Focus while Gossip isn't running, it stays stale until the next real Focus change or a
    /// peer's first state corrects it.
    private static let expectedStateDefaultsKey = "dev.vmd1.gossip.dnd.expectedState"

    init(transportManager: TransportManager, identity: IdentityKeyStore = .shared) {
        self.transportManager = transportManager
        self.identity = identity
        let persisted = UserDefaults.standard.object(forKey: Self.expectedStateDefaultsKey) as? Bool
        logic = GossipCoreKit.Dnd(persistedExpected: persisted)
        transportManager.router.register(prefix: "dnd.set") { [weak self] envelope in
            self?.handleDndSet(envelope)
        }
        // Peers' states arrive as a synchronised slot; a revoked device's slot is cleared (`valueJSON == nil`).
        transportManager.addOnStateChanged { [weak self] change in
            guard change.slot == GossipCoreKit.dndSlot() else { return }
            self?.handlePeerState(change)
        }
        // Publish the best-known state; the core sends it to every device that connects later.
        carryOut(logic.start())
    }

    // MARK: - Reporting (Mac -> peers)

    /// Parses a `connect://dnd?state=on|off` URL — as delivered to `AppDelegate` by the
    /// Shortcuts "When Focus is turned on/off" automations set up per `DNDSetupView` —
    /// and reports the new state. Returns `false` (and does nothing) for any URL that
    /// isn't a recognized `connect://dnd` request.
    @discardableResult
    func handleIncomingURL(_ url: URL) -> Bool {
        guard url.scheme == "connect", url.host == "dnd" else { return false }
        guard let enabled = Self.parseState(from: url) else {
            gossipError("Gossip: dnd URL missing/invalid 'state' query item: \(url)")
            return false
        }
        if isOwnShortcutActive() {
            gossipError("Gossip: ignoring dnd URL (\(enabled ? "on" : "off")) — echo of our own Shortcut")
            return true
        }
        lock.lock(); defer { lock.unlock() }
        carryOut(logic.localChanged(enabled: enabled, nowMs: Self.nowMs()))
        return true
    }

    /// Extracts `state=on` / `state=off` from a `connect://dnd?state=...` URL.
    static func parseState(from url: URL) -> Bool? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let stateValue = components.queryItems?.first(where: { $0.name == "state" })?.value else {
            return nil
        }
        switch stateValue {
        case "on": return true
        case "off": return false
        default: return nil
        }
    }

    // MARK: - Control (peers -> Mac)

    private func handleDndSet(_ envelope: Envelope) {
        guard let json = try? JSONEncoder().encode(envelope.payload) else { return }
        lock.lock(); defer { lock.unlock() }
        do {
            carryOut(try logic.onSet(payloadJson: String(decoding: json, as: UTF8.self), nowMs: Self.nowMs()))
        } catch {
            gossipError("Gossip: dnd.set payload rejected: \(error)")
        }
    }

    /// A peer's `dnd.state` slot changed. The first state seen from a device is OR-merged with this Mac's own; later changes
    /// are mirrored (see `desktop/core/src/features/dnd.rs`).
    private func handlePeerState(_ change: TransportManager.StateChange) {
        lock.lock(); defer { lock.unlock() }
        guard let json = change.valueJSON else {
            logic.forgetPeer(sender: change.deviceId)
            return
        }
        do {
            carryOut(try logic.onPeerState(sender: change.deviceId, valueJson: json, nowMs: Self.nowMs()))
        } catch {
            gossipError("Gossip: dnd.state payload rejected: \(error)")
        }
    }

    private func carryOut(_ effects: [GossipCoreKit.DndEffect]) {
        for effect in effects {
            switch effect {
            case .setState(let slot, let valueJson):
                transportManager?.setState(slot: slot, valueJSON: valueJson)
            case .applyLocal(let enabled):
                runShortcut(named: enabled ? "Connect Turn On DND" : "Connect Turn Off DND")
            case .persist(let expected):
                if let expected {
                    UserDefaults.standard.set(expected, forKey: Self.expectedStateDefaultsKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: Self.expectedStateDefaultsKey)
                }
            }
        }
    }

    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// Runs a user-created Shortcut by exact name via the `shortcuts` CLI — the only way
    /// to change Focus/DND state on macOS in the absence of a public API. See
    /// `DNDSetupView` for the required Shortcut setup.
    ///
    /// Shortcuts run one at a time, in order, on `shortcutQueue`. Launching them concurrently let a quick on/off pair finish
    /// out of order (leaving Focus opposite to what was requested), and each finished run fires a Focus automation whose
    /// `connect://dnd` callback can land well after the core's 3 s cooldown (which starts when the apply is *decided*, not
    /// when the Shortcut finishes) and be mistaken for a user change, which republishes it and makes the peer flip back.
    private func runShortcut(named name: String) {
        shortcutLock.lock()
        shortcutsInFlight += 1
        shortcutLock.unlock()
        shortcutQueue.async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["run", name]
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                gossipError("Gossip: failed to run Shortcut \"\(name)\": \(error)")
            }
            guard let self else { return }
            self.shortcutLock.lock()
            self.shortcutsInFlight -= 1
            self.lastShortcutFinishedMs = Self.nowMs()
            self.shortcutLock.unlock()
        }
    }

    /// True while one of our own Shortcuts is running or finished moments ago, so a Focus change reported now is the echo of
    /// what we just did rather than something the user did.
    private func isOwnShortcutActive() -> Bool {
        shortcutLock.lock(); defer { shortcutLock.unlock() }
        return shortcutsInFlight > 0 || Self.nowMs() - lastShortcutFinishedMs < Self.echoSettleMs
    }
}
