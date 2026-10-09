import Foundation
import Combine

/// This Mac's relay preferences (`UserDefaults`, never sent over the wire). Off by default: until the user turns it on,
/// the app opens no relay socket at all.
final class RelaySettings: ObservableObject {
    static let shared = RelaySettings()

    private let defaults: UserDefaults
    private static let enabledKey = "relay.enabled"
    private static let customURLKey = "relay.customURL"

    @Published private(set) var enabled: Bool
    @Published private(set) var customURL: String

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: Self.enabledKey)
        customURL = defaults.string(forKey: Self.customURLKey) ?? ""
    }

    func setEnabled(_ value: Bool) {
        defaults.set(value, forKey: Self.enabledKey)
        enabled = value
    }

    func setCustomURL(_ value: String) {
        defaults.set(value, forKey: Self.customURLKey)
        customURL = value
    }

    /// What the engine should be configured with: `nil` origin means the relay cannot be used (placeholder default and no
    /// valid custom address), so no socket is attempted.
    var configuration: (enabled: Bool, origin: String?) {
        guard enabled, case .success(let origin)? = RelayEndpointPolicy.resolveOrigin(customURL: customURL) else {
            return (false, nil)
        }
        return (true, origin)
    }
}

/// Persists the mesh topic secret and epoch the engine reports (`TopicChanged`). The secret decides who can find this
/// mesh on the relay, so it lives in the Keychain like the identity keys (a throwaway file under XCTest).
final class RelayTopicStore {
    static let shared = RelayTopicStore()

    private struct Stored: Codable {
        var secret: Data
        var epoch: UInt64
    }

    private let blob: SecretBlobStore

    init(blob: SecretBlobStore) { self.blob = blob }

    convenience init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Connect", isDirectory: true)
        self.init(blob: ProductionBlobStore.make(account: "relay-topic", legacyFile: dir.appendingPathComponent("relay-topic.json")))
    }

    func load() -> (secret: Data, epoch: UInt64)? {
        guard let data = blob.read(), let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.secret.count == 32 else { return nil }
        return (stored.secret, stored.epoch)
    }

    @discardableResult
    func save(secret: Data, epoch: UInt64) -> Bool {
        guard let data = try? JSONEncoder().encode(Stored(secret: secret, epoch: epoch)) else { return false }
        return blob.write(data)
    }
}
