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

    func testThePlaceholderDefaultIsNotUsable() {
        XCTAssertFalse(RelayEndpointPolicy.isDefaultConfigured)
        XCTAssertNil(RelayEndpointPolicy.resolveOrigin(customURL: ""), "no host configured, so no origin")
        XCTAssertNil(RelayEndpointPolicy.resolveOrigin(customURL: "   "))
        if case .success(let origin)? = RelayEndpointPolicy.resolveOrigin(customURL: "wss://my.example.com/connect") {
            XCTAssertEqual(origin, "wss://my.example.com")
        } else { XCTFail("a custom address is used") }
        if case .failure? = RelayEndpointPolicy.resolveOrigin(customURL: "ws://my.example.com") {} else { XCTFail("an insecure custom address is an error, not a silent fallback") }
    }

    func testConnectURLMustBeWssToAnAllowedHost() {
        let custom = "wss://my.example.com"
        XCTAssertNotNil(RelayEndpointPolicy.validateConnectURL("wss://my.example.com/connect", customURL: custom, allowInsecureLoopback: false))
        XCTAssertNil(RelayEndpointPolicy.validateConnectURL("wss://other.example.com/connect", customURL: custom, allowInsecureLoopback: false), "not the configured host")
        XCTAssertNil(RelayEndpointPolicy.validateConnectURL("wss://my.example.com/connect", customURL: "", allowInsecureLoopback: false), "no custom address and the default is a placeholder")
        XCTAssertNil(RelayEndpointPolicy.validateConnectURL("wss://relay.gossip.invalid/connect", customURL: "", allowInsecureLoopback: false))
        XCTAssertNil(RelayEndpointPolicy.validateConnectURL("ws://my.example.com/connect", customURL: custom, allowInsecureLoopback: false))
        XCTAssertNil(RelayEndpointPolicy.validateConnectURL("ws://127.0.0.1:9/connect", customURL: "", allowInsecureLoopback: false), "release builds never allow ws://")
        XCTAssertNotNil(RelayEndpointPolicy.validateConnectURL("ws://127.0.0.1:9/connect", customURL: "", allowInsecureLoopback: true))
        XCTAssertNil(RelayEndpointPolicy.validateConnectURL("ws://example.com/connect", customURL: "", allowInsecureLoopback: true))
        XCTAssertNil(RelayEndpointPolicy.validateConnectURL("wss://u:p@my.example.com/connect", customURL: custom, allowInsecureLoopback: false))
        XCTAssertNil(RelayEndpointPolicy.validateConnectURL("https://my.example.com/connect", customURL: custom, allowInsecureLoopback: false))
    }

    func testLoggableShowsOnlyTheHost() {
        let url = URL(string: "wss://my.example.com/connect?token=secret")!
        XCTAssertEqual(RelayEndpointPolicy.loggable(url), "my.example.com")
    }

    func testStatusLines() {
        XCTAssertEqual(RelayStatusText.line(enabled: false, hasOrigin: false, status: "disabled", errorCode: nil), "Off")
        XCTAssertEqual(RelayStatusText.line(enabled: true, hasOrigin: false, status: "disabled", errorCode: nil), "No relay host configured")
        XCTAssertEqual(RelayStatusText.line(enabled: true, hasOrigin: true, status: "joined", errorCode: nil), "Connected to the relay")
        XCTAssertTrue(RelayStatusText.line(enabled: true, hasOrigin: true, status: "disconnected", errorCode: "upgrade_required").contains("newer version"))
    }

    func testRelaySettingsDefaultOffAndPersist() {
        let defaults = UserDefaults(suiteName: "RelaySettingsTests-\(UUID().uuidString)")!
        let settings = RelaySettings(defaults: defaults)
        XCTAssertFalse(settings.enabled)
        XCTAssertNil(settings.configuration.origin)
        settings.setEnabled(true)
        XCTAssertNil(settings.configuration.origin, "enabled with the placeholder default: still no origin, so no connection")
        XCTAssertFalse(settings.configuration.enabled)
        settings.setCustomURL("wss://my.example.com")
        XCTAssertEqual(settings.configuration.origin, "wss://my.example.com")
        let reloaded = RelaySettings(defaults: defaults)
        XCTAssertTrue(reloaded.enabled)
        XCTAssertEqual(reloaded.customURL, "wss://my.example.com")
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
