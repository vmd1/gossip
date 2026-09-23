import Foundation

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
/// **Auto-reconciliation**: a `dnd.update` that disagrees with `expectedState` is also
/// applied locally (same as `dnd.set`), so toggling either device's Focus/DND mirrors
/// onto the other. This mirroring, plus running a Shortcut to apply a peer's request,
/// creates a feedback loop risk: running "Connect Turn On/Off DND" changes this Mac's
/// Focus, which itself fires the "When Focus is turned on/off" automation, delivering
/// another `connect://dnd` call for the *same* change we just made. `expectedState`
/// dedupes that (same convention as `clipboard.update`, see `schema/message-types.md`),
/// and `reconcileCooldown` is a belt-and-suspenders guard against that automation's
/// delivery timing racing the in-memory state update.
final class DNDSyncManager {
    private weak var transportManager: TransportManager?
    private let identity: IdentityKeyStore

    /// The DND/Focus state this Mac is currently believed to be in — either the last
    /// state we reported ourselves, or the last peer-requested state we applied. Used to
    /// dedupe echoes of our own changes (see class doc).
    ///
    /// Persisted (not just in-memory): macOS has no API to *read* current Focus state, so
    /// on a fresh launch this is the only way this Mac has any idea what it's in — without
    /// persistence, every relaunch would start from "unknown" even if the Shortcuts
    /// automations had reported real state just before quitting. This is still only a
    /// best-effort belief, not a live read: if the user changes Focus while Connect isn't
    /// running (no automation fires to tell it), this stays stale until the next real
    /// Focus change or a peer's `isInitialSync` report corrects it.
    private var expectedState: Bool? {
        get {
            UserDefaults.standard.object(forKey: Self.expectedStateDefaultsKey) as? Bool
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: Self.expectedStateDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.expectedStateDefaultsKey)
            }
        }
    }
    private static let expectedStateDefaultsKey = "com.connect.app.dnd.expectedState"

    /// When we last ran a Shortcut to apply a peer-requested state change.
    private var lastAppliedAt: Date?
    private let reconcileCooldown: TimeInterval = 3.0

    init(transportManager: TransportManager, identity: IdentityKeyStore = .shared) {
        self.transportManager = transportManager
        self.identity = identity
        transportManager.router.register(prefix: "dnd.set") { [weak self] envelope in
            self?.handleDndSet(envelope)
        }
        transportManager.router.register(prefix: "dnd.update") { [weak self] envelope in
            self?.handleDndUpdate(envelope)
        }
    }

    // MARK: - Reporting (Mac -> Android)

    /// Parses a `connect://dnd?state=on|off` URL — as delivered to `AppDelegate` by the
    /// Shortcuts "When Focus is turned on/off" automations set up per `DNDSetupView` —
    /// and reports the new state to the paired device. Returns `false` (and does
    /// nothing) for any URL that isn't a recognized `connect://dnd` request.
    @discardableResult
    func handleIncomingURL(_ url: URL) -> Bool {
        guard url.scheme == "connect", url.host == "dnd" else { return false }
        guard let enabled = Self.parseState(from: url) else {
            NSLog("Connect: dnd URL missing/invalid 'state' query item: \(url)")
            return false
        }

        if let lastAppliedAt, Date().timeIntervalSince(lastAppliedAt) < reconcileCooldown {
            return true
        }
        guard enabled != expectedState else { return true }

        expectedState = enabled
        reportState(enabled: enabled)
        return true
    }

    /// Sends this Mac's best-known current state as an `isInitialSync` report — call once
    /// per fresh connection. Unlike the plain `reportState` path (which only fires on an
    /// observed local change), this always sends, since the point is telling a peer we may
    /// never have told before. `expectedState ?? false` — "assume off if we've genuinely
    /// never observed anything" — is the best available answer given macOS has no API to
    /// read real Focus state; see `expectedState`'s doc.
    ///
    /// Two devices that were apart can each have a different real DND state with neither
    /// side having done anything wrong — nothing synced them yet. Blindly mirroring
    /// whichever report arrives would let concurrent reports from both sides *swap* their
    /// states (each mirrors the other's stale value). `handleDndUpdate`'s `isInitialSync`
    /// branch instead ORs the peer's reported state with this Mac's own known state: DND
    /// ends up on if *either* side had it on, which both sides converge to independently
    /// and order-independently, matching the same rule on the Android side
    /// (`DndSyncManager.reportInitialSyncState`/`handleInitialSync`).
    func reportInitialSyncState() {
        let enabled = expectedState ?? false
        expectedState = enabled
        reportState(enabled: enabled, isInitialSync: true)
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

    private func reportState(enabled: Bool, isInitialSync: Bool = false) {
        guard let transportManager else { return }
        let envelope = Envelope(
            type: "dnd.update",
            senderId: identity.deviceId,
            broadcast: true,
            payload: .object([
                "sourceDeviceId": .string(identity.deviceId),
                "enabled": .bool(enabled),
                "isInitialSync": .bool(isInitialSync)
            ])
        )
        do {
            try transportManager.send(envelope: envelope)
        } catch {
            NSLog("Connect: failed to send dnd.update: \(error)")
        }
    }

    // MARK: - Control (Android -> Mac)

    private func handleDndSet(_ envelope: Envelope) {
        guard case .bool(let enabled)? = envelope.payload["enabled"] else {
            NSLog("Connect: dnd.set missing boolean 'enabled' payload field")
            return
        }
        applyPeerState(enabled: enabled)
    }

    /// A `dnd.update` report from the peer that disagrees with what we believe this
    /// Mac's state should be is treated the same as an explicit `dnd.set` request — see
    /// class doc for why this is safe against feedback loops. An `isInitialSync` report
    /// instead goes through the OR-merge in `handleInitialSync` — see `reportInitialSyncState`'s
    /// doc for why a blind mirror is wrong for that case.
    private func handleDndUpdate(_ envelope: Envelope) {
        guard case .bool(let enabled)? = envelope.payload["enabled"] else {
            NSLog("Connect: dnd.update missing boolean 'enabled' payload field")
            return
        }
        if case .bool(true)? = envelope.payload["isInitialSync"] {
            handleInitialSync(remoteEnabled: enabled)
            return
        }
        guard enabled != expectedState else { return }
        applyPeerState(enabled: enabled)
    }

    /// OR-merges an `isInitialSync` peer report against this Mac's own known state (see
    /// `reportInitialSyncState`'s doc). Only actually applies anything if the merge
    /// disagrees with what we already believe.
    private func handleInitialSync(remoteEnabled: Bool) {
        let localEnabled = expectedState ?? false
        let target = localEnabled || remoteEnabled
        if target != localEnabled {
            applyPeerState(enabled: target)
        } else {
            expectedState = target
        }
    }

    private func applyPeerState(enabled: Bool) {
        expectedState = enabled
        lastAppliedAt = Date()
        runShortcut(named: enabled ? "Connect Turn On DND" : "Connect Turn Off DND")
    }

    /// Runs a user-created Shortcut by exact name via the `shortcuts` CLI — the only way
    /// to change Focus/DND state on macOS in the absence of a public API. See
    /// `DNDSetupView` for the required Shortcut setup. Note: under App Sandbox, spawning
    /// `/usr/bin/shortcuts` this way may require additional entitlement work verified on
    /// a real machine (see the PR's manual verification checklist) — this could not be
    /// exercised in this environment.
    private func runShortcut(named name: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", name]
        do {
            try process.run()
        } catch {
            NSLog("Connect: failed to run Shortcut \"\(name)\": \(error)")
        }
    }
}
