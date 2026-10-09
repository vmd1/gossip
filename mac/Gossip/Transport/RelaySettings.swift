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

    /// What the engine should be configured with. `nil` origin only when the custom address is invalid (a typo must not
    /// silently send traffic elsewhere). Otherwise: custom address, else the directory's relay, else the built-in default.
    ///
    /// `awaitingDirectory` is true on a first run with polling on and nothing cached, until the first poll has finished
    /// (it is bounded by the 10 s request timeout): the relay is held back rather than connecting to the default when
    /// the directory is about to say otherwise. A custom address never waits.
    func configuration(directoryOrigin: String? = nil, directoryIsFresh: Bool = false, awaitingDirectory: Bool = false) -> (enabled: Bool, origin: String?, resolution: RelayEndpointPolicy.Resolution?) {
        guard case .success(let resolution) = RelayEndpointPolicy.resolve(customURL: customURL, directoryOrigin: directoryOrigin, directoryIsFresh: directoryIsFresh) else {
            return (false, nil, nil)
        }
        if awaitingDirectory && resolution.source == .builtInDefault { return (false, nil, resolution) }
        return (enabled, resolution.origin, resolution)
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
