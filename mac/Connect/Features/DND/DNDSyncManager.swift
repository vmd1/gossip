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
final class DNDSyncManager {
    private weak var transportManager: TransportManager?
    private let identity: IdentityKeyStore

    init(transportManager: TransportManager, identity: IdentityKeyStore = .shared) {
        self.transportManager = transportManager
        self.identity = identity
        transportManager.router.register(prefix: "dnd.set") { [weak self] envelope in
            self?.handleDndSet(envelope)
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
        reportState(enabled: enabled)
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

    private func reportState(enabled: Bool) {
        guard let transportManager else { return }
        let envelope = Envelope(
            type: "dnd.update",
            senderId: identity.deviceId,
            broadcast: true,
            payload: .object([
                "sourceDeviceId": .string(identity.deviceId),
                "enabled": .bool(enabled)
            ])
        )
        try? transportManager.send(envelope: envelope)
    }

    // MARK: - Control (Android -> Mac)

    private func handleDndSet(_ envelope: Envelope) {
        guard case .bool(let enabled)? = envelope.payload["enabled"] else {
            NSLog("Connect: dnd.set missing boolean 'enabled' payload field")
            return
        }
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
