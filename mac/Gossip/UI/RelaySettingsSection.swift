import SwiftUI

/// What the Settings status line says about the relay, from the engine's `relay_status` string.
enum RelayStatusText {
    static func line(enabled: Bool, hasOrigin: Bool, status: String, errorCode: String?) -> String {
        guard enabled else { return "Off" }
        guard hasOrigin else { return "No relay host configured" }
        switch status {
        case "joined": return "Connected to the relay"
        case "connecting": return "Connecting…"
        case "disconnected":
            if let errorCode, let hint = hint(for: errorCode) { return hint }
            return "Not connected — retrying"
        case "no_topic": return "Waiting for a paired device on the same network (the first connection sets the relay up)"
        default: return "Off"
        }
    }

    private static func hint(for code: String) -> String? {
        switch code {
        case "upgrade_required": return "The relay needs a newer version of Gossip"
        case "denied", "join_failed": return "The relay refused this device — retrying"
        case "disabled": return "The relay is switched off by its operator"
        default: return nil
        }
    }
}

/// Settings > Relay: the opt-in for connecting to paired devices when they are not on the same network.
struct RelaySettingsSection: View {
    @ObservedObject var settings: RelaySettings
    @ObservedObject var transport: TransportManager
    @State private var customURLText: String
    @State private var validationError: String?

    init(settings: RelaySettings, transport: TransportManager) {
        self.settings = settings
        self.transport = transport
        _customURLText = State(initialValue: settings.customURL)
    }

    private var hasOrigin: Bool {
        if case .success? = RelayEndpointPolicy.resolveOrigin(customURL: settings.customURL) { return true }
        return false
    }

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { settings.enabled }, set: { settings.setEnabled($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Relay (connect when not on the same network)")
                    Text("Keeps your paired devices connected over the internet when they are not on the same network. Same-network connections are always preferred.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            TextField("Custom relay address (optional)", text: $customURLText, prompt: Text("wss://relay.example.com"))
                .autocorrectionDisabled()
                .onSubmit(commitCustomURL)
                .onChange(of: customURLText) { _, _ in validationError = nil }
            if let validationError {
                Text(validationError).font(.caption).foregroundStyle(.red)
            }
            LabeledContent("Status") {
                Text(RelayStatusText.line(enabled: settings.enabled, hasOrigin: hasOrigin, status: transport.relayStatus, errorCode: transport.relayErrorCode))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Relay")
        } footer: {
            Text("The relay sees which network addresses connect and when, and how much data flows, but not what you send: everything is end-to-end encrypted between your devices. Screen mirroring and Universal Control only work on the same network. Press Return after typing a custom address.")
                .font(.caption)
        }
        .onDisappear(perform: commitCustomURL)
    }

    private func commitCustomURL() {
        let text = customURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            settings.setCustomURL("")
            validationError = nil
            return
        }
        switch RelayEndpointPolicy.normalizeOrigin(text) {
        case .success(let origin):
            customURLText = origin
            settings.setCustomURL(origin)
            validationError = nil
        case .failure(let failure):
            validationError = Self.message(for: failure)
        }
    }

    static func message(for failure: RelayEndpointPolicy.Failure) -> String {
        switch failure {
        case .malformed: return "That is not a valid address. Use the form wss://relay.example.com"
        case .insecureScheme: return "The address must start with wss:// (an encrypted connection)."
        case .credentialsNotAllowed: return "Do not put a user name or password in the address."
        case .unexpectedComponents: return "Use just the host, like wss://relay.example.com (no path or query)."
        case .hostNotAllowed: return "That host is not allowed."
        }
    }
}
