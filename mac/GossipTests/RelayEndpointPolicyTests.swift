import XCTest
@testable import Gossip

final class RelayEndpointPolicyTests: XCTestCase {
    private func origin(_ text: String, insecure: Bool = false) -> String? {
        if case .success(let value) = RelayEndpointPolicy.normalizeOrigin(text, allowInsecureLoopback: insecure) { return value }
        return nil
    }

    func testAcceptsWssAndNormalizes() {
        XCTAssertEqual(origin("wss://Relay.Example.com"), "wss://relay.example.com")
        XCTAssertEqual(origin(" wss://relay.example.com/ "), "wss://relay.example.com")
        XCTAssertEqual(origin("wss://relay.example.com/connect"), "wss://relay.example.com")
        XCTAssertEqual(origin("wss://relay.example.com:8443"), "wss://relay.example.com:8443")
    }

    func testRejectsInsecureOrMalformedAddresses() {
        for bad in ["", "relay.example.com", "https://relay.example.com", "ws://relay.example.com", "ws://192.168.1.5:8080",
                    "wss://user:pw@relay.example.com", "wss://relay.example.com/other", "wss://relay.example.com?token=1",
                    "wss://relay.example.com#x", "wss://", "wss://relay.example.com:0", "wss://relay.example.com:99999"] {
            XCTAssertNil(origin(bad), bad)
        }
        XCTAssertEqual(RelayEndpointPolicy.normalizeOrigin("ws://relay.example.com"), .failure(.insecureScheme))
        XCTAssertEqual(RelayEndpointPolicy.normalizeOrigin("wss://u:p@relay.example.com"), .failure(.credentialsNotAllowed))
    }

    func testPlainWsIsOnlyForLoopbackAndOnlyWhenAllowed() {
        XCTAssertNil(origin("ws://127.0.0.1:8080"), "release behaviour")
        XCTAssertEqual(origin("ws://127.0.0.1:8080", insecure: true), "ws://127.0.0.1:8080")
        XCTAssertEqual(origin("ws://localhost:8080", insecure: true), "ws://localhost:8080")
        XCTAssertNil(origin("ws://example.com", insecure: true), "never for a non-loopback host")
        XCTAssertNil(origin("ws://127.0.0.1.evil.com", insecure: true))
    }

    func testResolutionOrderIsCustomThenDirectoryThenDefault() {
        func resolve(_ custom: String, _ directory: String?, fresh: Bool = true) -> RelayEndpointPolicy.Resolution? {
            if case .success(let value) = RelayEndpointPolicy.resolve(customURL: custom, directoryOrigin: directory, directoryIsFresh: fresh, allowInsecureLoopback: false) { return value }
            return nil
        }
        XCTAssertEqual(resolve("", nil), .init(origin: "wss://gossip.vmd1.dev", source: .builtInDefault))
        XCTAssertEqual(resolve("  ", nil)?.source, .builtInDefault)
        XCTAssertEqual(resolve("", "wss://eu.vmd1.dev"), .init(origin: "wss://eu.vmd1.dev", source: .directory))
        XCTAssertEqual(resolve("", "wss://eu.vmd1.dev", fresh: false)?.source, .cachedOffline)
        XCTAssertEqual(resolve("wss://my.example.com/connect", "wss://eu.vmd1.dev"), .init(origin: "wss://my.example.com", source: .custom), "custom wins")
        XCTAssertEqual(resolve("", "ws://evil.example.com")?.source, .builtInDefault, "an unusable directory answer falls back to the default")
        if case .failure = RelayEndpointPolicy.resolve(customURL: "ws://my.example.com", directoryOrigin: "wss://eu.vmd1.dev", allowInsecureLoopback: false) {} else { XCTFail("an invalid custom address is an error, not a silent fallback") }
        XCTAssertEqual(resolve("", nil)?.host, "gossip.vmd1.dev")
    }

    func testAllowedHostsAreTheVmd1DevDomain() {
        for host in ["vmd1.dev", "gossip.vmd1.dev", "a.b.vmd1.dev"] { XCTAssertTrue(RelayEndpointPolicy.isAllowedHost(host), host) }
        for host in ["evilvmd1.dev", "vmd1.dev.evil.com", "gossip.vmd1.dev.evil.com", "vmd1.devx", "dev", ""] { XCTAssertFalse(RelayEndpointPolicy.isAllowedHost(host), host) }
    }

    func testDirectoryEndpointIsAPlaceholderUntilTheOperatorSetsIt() {
        XCTAssertTrue(RelayEndpointPolicy.directoryEndpointIsPlaceholder)
        XCTAssertTrue(RelayEndpointPolicy.directoryEndpoint.hasPrefix("https://"))
    }

    func testLoggableShowsOnlyTheHost() {
        let url = URL(string: "wss://my.example.com/connect?token=secret")!
        XCTAssertEqual(RelayEndpointPolicy.loggable(url), "my.example.com")
    }

    func testStatusLines() {
        XCTAssertEqual(RelayStatusText.line(enabled: false, hasOrigin: false, status: "disabled", errorCode: nil), "Off")
        XCTAssertEqual(RelayStatusText.line(enabled: true, hasOrigin: false, status: "disabled", errorCode: nil), "The custom relay address is not valid")
        XCTAssertEqual(RelayStatusText.line(enabled: true, hasOrigin: true, status: "joined", errorCode: nil), "Connected to the relay")
        XCTAssertTrue(RelayStatusText.line(enabled: true, hasOrigin: true, status: "disconnected", errorCode: "upgrade_required").contains("newer version"))
    }

    func testRelaySettingsDefaultOffAndPersist() {
        let defaults = UserDefaults(suiteName: "RelaySettingsTests-\(UUID().uuidString)")!
        let settings = RelaySettings(defaults: defaults)
        XCTAssertFalse(settings.enabled)
        XCTAssertFalse(settings.configuration().enabled)
        settings.setEnabled(true)
        XCTAssertTrue(settings.configuration().enabled)
        XCTAssertEqual(settings.configuration().origin, "wss://gossip.vmd1.dev", "the built-in default needs no setup")
        XCTAssertEqual(settings.configuration(directoryOrigin: "wss://eu.vmd1.dev", directoryIsFresh: true).origin, "wss://eu.vmd1.dev")
        settings.setCustomURL("wss://my.example.com")
        XCTAssertEqual(settings.configuration(directoryOrigin: "wss://eu.vmd1.dev").origin, "wss://my.example.com")
        settings.setCustomURL("ws://bad.example.com")
        XCTAssertNil(settings.configuration().origin, "an invalid custom address never silently falls back")
        let reloaded = RelaySettings(defaults: defaults)
        XCTAssertTrue(reloaded.enabled)
        XCTAssertEqual(reloaded.customURL, "ws://bad.example.com")
    }

    func testTopicStoreRoundTripsAndRejectsBadData() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("topic-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = RelayTopicStore(blob: FileBlobStore(url: url))
        XCTAssertNil(store.load())
        XCTAssertTrue(store.save(secret: Data(repeating: 9, count: 32), epoch: 3))
        XCTAssertEqual(store.load()?.epoch, 3)
        XCTAssertEqual(store.load()?.secret, Data(repeating: 9, count: 32))
        try? Data("junk".utf8).write(to: url)
        XCTAssertNil(store.load())
    }

    func testConnectivityClassifiesRelayedBetweenDirectAndMesh() {
        XCTAssertEqual(DeviceConnectivity.classify("a", directIds: ["a"], meshIds: [], relayedIds: ["a"]), .direct)
        XCTAssertEqual(DeviceConnectivity.classify("b", directIds: [], meshIds: ["b"], relayedIds: ["b"]), .relayed)
    }
}
