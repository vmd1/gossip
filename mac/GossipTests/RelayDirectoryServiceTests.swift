import XCTest
import GossipCoreKit
@testable import Gossip

/// The directory service with a fake HTTP layer and a controllable clock. The validation rules themselves are covered
/// by the Rust unit tests; these cover the shell: caching, persistence across restarts, never overwriting a good cache
/// with a bad answer, and reconfiguring on change.
final class RelayDirectoryServiceTests: XCTestCase {
    private final class FakeHTTP: RelayDirectoryHTTP {
        var response: Data?
        private(set) var calls = 0
        func fetch(_ url: URL, completion: @escaping (Data?) -> Void) { calls += 1; completion(response) }
    }

    private final class Clock { var date = Date(timeIntervalSince1970: 1_800_000_000) }

    private let endpoint = "https://gossip.vmd1.dev/relay.json"
    private var cacheURL: URL!

    override func setUp() {
        cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent("relay-dir-\(UUID().uuidString)/relay-directory.json")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }

    private func blob(_ server: String, extra: String = "") -> Data { Data(#"{"relayServer":"\#(server)"\#(extra)}"#.utf8) }

    private func makeService(http: FakeHTTP, clock: Clock, endpoint: String? = nil) -> RelayDirectoryService {
        RelayDirectoryService(endpoint: endpoint ?? self.endpoint, http: http, cacheURL: cacheURL, allowInsecureLocal: false,
                              scheduler: RelayDirectoryScheduler.withJitterPermille(jitterPermille: 0), now: { clock.date })
    }

    /// Lets the service queue and the main-queue publish run.
    private func settle(_ service: RelayDirectoryService) {
        service.flush()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        service.flush()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    func testValidFetchIsCachedAndApplied() throws {
        let http = FakeHTTP(); let clock = Clock()
        http.response = blob("wss://eu.vmd1.dev", extra: #","unknown":[1]"#)
        let service = makeService(http: http, clock: clock)
        XCTAssertNil(service.cachedOrigin)
        service.setActive(true); settle(service)
        XCTAssertEqual(http.calls, 1, "polls on launch")
        XCTAssertEqual(service.cachedOrigin, "wss://eu.vmd1.dev")
        XCTAssertTrue(service.isFresh)
        XCTAssertNotNil(service.lastSuccess)
        let file = try JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any]
        XCTAssertEqual(file?["raw"] as? String, String(data: http.response!, encoding: .utf8), "the raw blob is kept exactly as received")
        XCTAssertNotNil(file?["fetchedAt"])
    }

    func testUnreachableDirectoryKeepsAndUsesTheCacheAcrossRestart() {
        let http = FakeHTTP(); let clock = Clock()
        http.response = blob("wss://eu.vmd1.dev")
        let first = makeService(http: http, clock: clock)
        first.setActive(true); settle(first)
        XCTAssertEqual(first.cachedOrigin, "wss://eu.vmd1.dev")

        // "Restart" with the directory down.
        let down = FakeHTTP(); down.response = nil
        let second = makeService(http: down, clock: clock)
        XCTAssertEqual(second.cachedOrigin, "wss://eu.vmd1.dev", "loaded from disk before any network")
        XCTAssertFalse(second.isFresh, "from the cache, not refreshed: shown as cached (offline)")
        XCTAssertNotNil(second.lastSuccess)
        second.setActive(true); settle(second)
        XCTAssertEqual(down.calls, 1)
        XCTAssertEqual(second.cachedOrigin, "wss://eu.vmd1.dev", "a failed fetch does not clear the cache")
        XCTAssertFalse(second.isFresh)
        let source = RelayEndpointPolicy.resolve(customURL: "", directoryOrigin: second.cachedOrigin, directoryIsFresh: second.isFresh, allowInsecureLoopback: false)
        XCTAssertEqual((try? source.get())?.source, .cachedOffline)
    }

    func testInvalidOrMaliciousFetchNeverOverwritesTheCache() throws {
        let http = FakeHTTP(); let clock = Clock()
        http.response = blob("wss://eu.vmd1.dev")
        let service = makeService(http: http, clock: clock)
        service.setActive(true); settle(service)
        let good = try Data(contentsOf: cacheURL)

        let bad: [Data] = [
            blob("wss://gossip.vmd1.dev.evil.com"), blob("wss://evil.com"), blob("ws://127.0.0.1:1"), Data("not json".utf8),
            Data("[]".utf8), Data(#"{"relayServer":7}"#.utf8), Data([0xff, 0xfe, 0x00]),
            Data(#"{"relayServer":"wss://eu.vmd1.dev","pad":"\#(String(repeating: "a", count: 20_000))"}"#.utf8),
        ]
        for body in bad {
            http.response = body
            clock.date.addTimeInterval(7 * 3600)
            service.tick(); settle(service)
            XCTAssertEqual(service.cachedOrigin, "wss://eu.vmd1.dev")
            XCTAssertEqual(try Data(contentsOf: cacheURL), good, "the file is untouched")
            XCTAssertFalse(service.isFresh)
            clock.date.addTimeInterval(31 * 60) // past any backoff
        }
        XCTAssertEqual(http.calls, 1 + bad.count)
    }

    func testMaliciousFirstFetchLeavesNoCacheAndTheDefaultApplies() {
        let http = FakeHTTP(); let clock = Clock()
        http.response = blob("wss://evil.example.com")
        let service = makeService(http: http, clock: clock)
        service.setActive(true); settle(service)
        XCTAssertNil(service.cachedOrigin)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    func testChangedRelayServerIsPickedUpAndReplacesTheCache() {
        let http = FakeHTTP(); let clock = Clock()
        http.response = blob("wss://a.vmd1.dev")
        let service = makeService(http: http, clock: clock)
        var seen: [String?] = []
        let sub = service.$cachedOrigin.sink { seen.append($0) }
        service.setActive(true); settle(service)
        http.response = blob("wss://b.vmd1.dev")
        clock.date.addTimeInterval(7 * 3600)
        service.tick(); settle(service)
        XCTAssertEqual(service.cachedOrigin, "wss://b.vmd1.dev")
        XCTAssertEqual(seen, [nil, "wss://a.vmd1.dev", "wss://b.vmd1.dev"])
        // Re-fetching the same answer is not a change.
        clock.date.addTimeInterval(7 * 3600)
        service.tick(); settle(service)
        XCTAssertEqual(seen.count, 3)
        sub.cancel()
        let reloaded = makeService(http: FakeHTTP(), clock: clock)
        XCTAssertEqual(reloaded.cachedOrigin, "wss://b.vmd1.dev")
    }

    func testPollingFollowsTheScheduleAndOnlyWhileActive() {
        let http = FakeHTTP(); let clock = Clock()
        http.response = blob("wss://a.vmd1.dev")
        let service = makeService(http: http, clock: clock)
        service.tick(); settle(service)
        XCTAssertEqual(http.calls, 0, "inactive: relay is off, no polling")
        service.setActive(true); settle(service)
        XCTAssertEqual(http.calls, 1)
        clock.date.addTimeInterval(3600)
        service.tick(); settle(service)
        XCTAssertEqual(http.calls, 1, "not due yet")
        clock.date.addTimeInterval(6 * 3600)
        service.tick(); settle(service)
        XCTAssertEqual(http.calls, 2, "due after six hours")
        service.setActive(false); settle(service)
        clock.date.addTimeInterval(24 * 3600)
        service.tick(); settle(service)
        XCTAssertEqual(http.calls, 2)
    }

    func testFailuresBackOffAndConnectFailureIsRateLimited() {
        let http = FakeHTTP(); let clock = Clock()
        http.response = nil
        let service = makeService(http: http, clock: clock)
        service.setActive(true); settle(service)
        XCTAssertEqual(http.calls, 1)
        clock.date.addTimeInterval(30)
        service.tick(); settle(service)
        XCTAssertEqual(http.calls, 1, "backoff is one minute")
        clock.date.addTimeInterval(31)
        service.tick(); settle(service)
        XCTAssertEqual(http.calls, 2)
        service.noteRelayConnectFailure(); settle(service)
        XCTAssertEqual(http.calls, 2, "a connect-failure poll within ten minutes of the last attempt is refused")
        clock.date.addTimeInterval(11 * 60)
        service.noteRelayConnectFailure(); settle(service)
        XCTAssertEqual(http.calls, 3)
    }

    func testPlaceholderEndpointNeverPolls() {
        let http = FakeHTTP(); let clock = Clock()
        http.response = blob("wss://a.vmd1.dev")
        let service = makeService(http: http, clock: clock, endpoint: RelayEndpointPolicy.directoryEndpoint)
        XCTAssertFalse(service.pollingEnabled)
        service.setActive(true); service.tick(); service.noteRelayConnectFailure(); settle(service)
        XCTAssertEqual(http.calls, 0)
        XCTAssertNil(service.cachedOrigin)
    }

    func testRelayWaitsForTheFirstDirectoryAnswerOnlyWhenNothingIsCached() {
        let http = FakeHTTP(); let clock = Clock()
        http.response = blob("wss://eu.vmd1.dev")
        let service = makeService(http: http, clock: clock)
        XCTAssertTrue(service.awaitingFirstAnswer)
        let defaults = UserDefaults(suiteName: "RelayWait-\(UUID().uuidString)")!
        let settings = RelaySettings(defaults: defaults)
        settings.setEnabled(true)
        XCTAssertFalse(settings.configuration(awaitingDirectory: true).enabled, "held back so it does not connect to the default first")
        settings.setCustomURL("wss://my.example.com")
        XCTAssertTrue(settings.configuration(awaitingDirectory: true).enabled, "a custom address never waits")
        service.setActive(true); settle(service)
        XCTAssertFalse(service.awaitingFirstAnswer)
        XCTAssertFalse(makeService(http: FakeHTTP(), clock: clock).awaitingFirstAnswer, "a cached answer means nothing to wait for")
        // A failed first poll also ends the wait (the default applies).
        try? FileManager.default.removeItem(at: cacheURL)
        let down = makeService(http: FakeHTTP(), clock: clock)
        XCTAssertTrue(down.awaitingFirstAnswer)
        down.setActive(true); settle(down)
        XCTAssertFalse(down.awaitingFirstAnswer)
        XCTAssertNil(down.cachedOrigin)
    }

    func testCorruptCacheFileIsIgnored() throws {
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        for junk in ["junk", #"{"fetchedAt":1,"raw":"{\"relayServer\":\"wss://evil.com\"}"}"#, #"{"fetchedAt":1,"raw":"nope"}"#] {
            try Data(junk.utf8).write(to: cacheURL)
            let service = makeService(http: FakeHTTP(), clock: Clock())
            XCTAssertNil(service.cachedOrigin, junk)
        }
        // And a good fetch repairs it.
        let http = FakeHTTP(); http.response = blob("wss://a.vmd1.dev")
        let service = makeService(http: http, clock: Clock())
        service.setActive(true); settle(service)
        XCTAssertEqual(service.cachedOrigin, "wss://a.vmd1.dev")
        XCTAssertEqual(makeService(http: FakeHTTP(), clock: Clock()).cachedOrigin, "wss://a.vmd1.dev")
    }

    func testRealHttpLayerRefusesNonHttpsAndCredentials() {
        XCTAssertTrue(URLSessionRelayDirectoryHTTP.isAcceptable(URL(string: "https://gossip.vmd1.dev/x")!, allowInsecureLoopback: false))
        XCTAssertFalse(URLSessionRelayDirectoryHTTP.isAcceptable(URL(string: "http://gossip.vmd1.dev/x")!, allowInsecureLoopback: true))
        XCTAssertFalse(URLSessionRelayDirectoryHTTP.isAcceptable(URL(string: "http://127.0.0.1:1/x")!, allowInsecureLoopback: false))
        XCTAssertTrue(URLSessionRelayDirectoryHTTP.isAcceptable(URL(string: "http://127.0.0.1:1/x")!, allowInsecureLoopback: true))
        XCTAssertFalse(URLSessionRelayDirectoryHTTP.isAcceptable(URL(string: "https://u:p@gossip.vmd1.dev/x")!, allowInsecureLoopback: false))
        XCTAssertFalse(URLSessionRelayDirectoryHTTP.isAcceptable(URL(string: "file:///etc/passwd")!, allowInsecureLoopback: true))
    }
}
