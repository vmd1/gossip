import SwiftUI

/// What the Settings status line says about the relay, from the engine's `relay_status` string.
enum RelayStatusText {
    static func line(enabled: Bool, hasOrigin: Bool, status: String, errorCode: String?) -> String {
        guard enabled else { return "Off" }
        guard hasOrigin else { return "The custom relay address is not valid" }
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

/// Which relay is in use and where that choice came from, for the Settings line.
enum RelaySourceText {
    static func label(_ source: RelayEndpointPolicy.Source) -> String {
        switch source {
        case .custom: return "custom"
        case .directory: return "directory"
        case .cachedOffline: return "cached (offline)"
        case .builtInDefault: return "default"
        }
    }

    static func lastCheck(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "never" }
        return date.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }
}

/// Settings > Relay: the opt-in for connecting to paired devices when they are not on the same network.
struct RelaySettingsSection: View {
    @ObservedObject var settings: RelaySettings
    @ObservedObject var transport: TransportManager
    @ObservedObject var directory: RelayDirectoryService
    @State private var customURLText: String
    @State private var validationError: String?

    init(settings: RelaySettings, transport: TransportManager) {
        self.settings = settings
        self.transport = transport
        self.directory = transport.relayDirectory
        _customURLText = State(initialValue: settings.customURL)
    }

    private var resolution: RelayEndpointPolicy.Resolution? {
        if case .success(let value) = RelayEndpointPolicy.resolve(customURL: settings.customURL, directoryOrigin: directory.cachedOrigin, directoryIsFresh: directory.isFresh) { return value }
        return nil
    }

    private var hasOrigin: Bool { resolution != nil }

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
            if let resolution {
                LabeledContent("Relay server") {
                    Text("\(resolution.host) (\(RelaySourceText.label(resolution.source)))").foregroundStyle(.secondary)
                }
                if !RelayEndpointPolicy.directoryEndpointIsPlaceholder {
                    LabeledContent("Directory last checked") {
                        Text(RelaySourceText.lastCheck(directory.lastSuccess)).foregroundStyle(.secondary)
                    }
                }
            }
            LabeledContent("Status") {
                Text(RelayStatusText.line(enabled: settings.enabled, hasOrigin: hasOrigin, status: transport.relayStatus, errorCode: transport.relayErrorCode))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Relay")
        } footer: {
            Text("The relay sees which network addresses connect and when, and how much data flows, but not what you send: everything is end-to-end encrypted between your devices. Screen mirroring and Universal Control only work on the same network. The relay address is looked up from a small directory so it can move without an app update; the last answer is kept and used when the directory is unreachable. A custom address overrides it. Press Return after typing a custom address.")
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
        }
    }
}
