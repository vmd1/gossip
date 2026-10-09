import XCTest
import CryptoKit
@testable import Gossip

/// End-to-end test of the relay path: two real `TransportManager`s in this process (real Rust engines, real Noise
/// sessions) that can only reach each other through a real relay server (`relay/`) over a real WebSocket
/// (`RelayConnection`). The LAN is off (`start(lan: false)`: no Bonjour, no listener), the identities and trust stores
/// are throwaway, and both start with the same pre-seeded mesh topic, since creating the topic normally takes a first
/// LAN connection.
///
/// Skipped unless `GOSSIP_E2E_RELAY` is set to the relay's origin (for example `ws://127.0.0.1:8099`); run it with
/// `scripts/e2e-relay.sh`, which starts the relay and passes the origin through (`TEST_RUNNER_` prefixed variables reach the
/// test process). `ws://127.0.0.1` is only accepted by Debug builds of the app (`RelayEndpointPolicy`), which is what the
/// test host is.
final class RelayE2ETests: XCTestCase {
    private final class Node {
        let name: String
        let identity: IdentityKeyStore
        let trust: TrustedDevicesStore
        let settings: RelaySettings
        let transport: TransportManager
        private let lock = NSLock()
        private var inbox: [Envelope] = []
        private var raws: [(Envelope, Data)] = []

        init(_ name: String, directory: URL, origin: String, topicSecret: Data) {
            self.name = name
            identity = IdentityKeyStore(fileURL: directory.appendingPathComponent("\(name)-identity.json"))
            trust = TrustedDevicesStore(fileURL: directory.appendingPathComponent("\(name)-trusted.json"))
            let defaults = UserDefaults(suiteName: "RelayE2E-\(name)-\(UUID().uuidString)")!
            settings = RelaySettings(defaults: defaults)
            settings.setCustomURL(origin)
            let topics = RelayTopicStore(blob: FileBlobStore(url: directory.appendingPathComponent("\(name)-topic.json")))
            topics.save(secret: topicSecret, epoch: 1)
            transport = TransportManager(trustedDevices: trust, identity: identity, relaySettings: settings, topicStore: topics)
            transport.router.register(prefix: "e2e.") { [weak self] envelope in
                self?.lock.lock(); self?.inbox.append(envelope); self?.lock.unlock()
            }
            transport.onRawFrameReceived = { [weak self] envelope, data in
                self?.lock.lock(); self?.raws.append((envelope, data)); self?.lock.unlock()
            }
        }

        var deviceId: String { identity.deviceId }

        func trusts(_ other: Node) {
            trust.addDevice(
                deviceId: other.deviceId,
                publicKeyBase64: other.identity.agreementKey.publicKey.rawRepresentation.base64EncodedString(),
                deviceName: other.name, deviceType: .mac,
                signingPublicKeyBase64: other.identity.signingKey.publicKey.rawRepresentation.base64EncodedString()
            )
        }

        func received(_ type: String) -> [Envelope] {
            lock.lock(); defer { lock.unlock() }
            return inbox.filter { $0.type == type }
        }

        func raw(_ type: String) -> (Envelope, Data)? {
            lock.lock(); defer { lock.unlock() }
            return raws.first { $0.0.type == type }
        }
    }

    private func wait(_ what: String, timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for \(what)", file: file, line: line); return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    func testTwoMacsTalkThroughTheRelay() throws {
        guard let origin = ProcessInfo.processInfo.environment["GOSSIP_E2E_RELAY"], !origin.isEmpty else {
            throw XCTSkip("set GOSSIP_E2E_RELAY (see scripts/e2e-relay.sh) to run the relay end-to-end test")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secret = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        let a = Node("alpha", directory: directory, origin: origin, topicSecret: secret)
        let b = Node("beta", directory: directory, origin: origin, topicSecret: secret)
        a.trusts(b); b.trusts(a)
        defer { a.transport.stop(); b.transport.stop() }

        // The relay is opt-in: turn it on exactly as the Settings toggle does.
        a.settings.setEnabled(true); b.settings.setEnabled(true)
        for node in [a, b] {
            node.transport.setLanGraceMs(0) // dial through the relay right away instead of after the LAN grace period
            node.transport.start(deviceName: node.name, lan: false)
        }

        // ---- Both devices join the topic and the lower device id dials the other through it. ----
        wait("both devices to be connected through the relay") {
            a.transport.relayedDeviceIds.contains(b.deviceId) && b.transport.relayedDeviceIds.contains(a.deviceId)
        }
        XCTAssertEqual(a.transport.connectionPath(for: b.deviceId), .relayed)
        XCTAssertTrue(a.transport.isRelayed(b.deviceId))
        XCTAssertFalse(a.transport.connectedDeviceIds.contains(b.deviceId), "relayed is not a same-network connection")
        XCTAssertFalse(a.transport.isDirectlyConnected(b.deviceId), "no Universal Control session may start for it")
        XCTAssertNil(a.transport.hostWithZone(for: b.deviceId), "no LAN address, so screen mirroring cannot start")
        if case .connected = a.transport.connectionState {} else { XCTFail("the aggregate state counts a relayed peer as connected") }
        XCTAssertEqual(a.transport.relayStatus, "joined")

        // ---- A message with a 1 MiB payload crosses the relay and comes back. ----
        let big = String(repeating: "0123456789abcdef", count: 65_536) // 1 MiB
        let ping = Envelope(type: "e2e.ping", senderId: a.deviceId, recipientId: b.deviceId, payload: .object([
            "title": .string("Héllo \"q\" 日本 😀"), "big": .string(big),
        ]))
        try a.transport.send(envelope: ping)
        wait("the ping at the other end") { !b.received("e2e.ping").isEmpty }
        let seen = try XCTUnwrap(b.received("e2e.ping").first)
        XCTAssertEqual(seen.id, ping.id)
        XCTAssertEqual(seen.senderId, a.deviceId)
        XCTAssertEqual(seen.payload["big"]?.stringValue?.count, big.count)
        XCTAssertEqual(seen.payload["title"]?.stringValue, "Héllo \"q\" 日本 😀")
        XCTAssertNotNil(seen.sig, "signed by the sender's engine and verified by the receiver's")

        try b.transport.send(envelope: Envelope(type: "e2e.pong", senderId: b.deviceId, recipientId: a.deviceId, payload: .object(["size": .number(Double(big.count))])))
        wait("the pong") { !a.received("e2e.pong").isEmpty }
        XCTAssertEqual(a.received("e2e.pong").first?.payload["size"]?.numberValue, Double(big.count))

        // ---- A raw follow-up frame (the clipboard-image path) crosses intact too. ----
        let raw = Data((0..<(2 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 2654435761 >> 7) })
        try a.transport.send(Envelope(type: "e2e.raw", senderId: a.deviceId, recipientId: b.deviceId, hasRawFollowup: true, payload: .object([:])), withRawFollowup: raw)
        wait("the raw frame") { b.raw("e2e.raw") != nil }
        XCTAssertEqual(b.raw("e2e.raw").map { SHA256.hash(data: $0.1).description }, SHA256.hash(data: raw).description)

        // ---- Turning the relay off drops the peer; turning it on again reconnects. ----
        a.settings.setEnabled(false)
        wait("the relayed peer to go away") { !a.transport.relayedDeviceIds.contains(b.deviceId) }
        XCTAssertEqual(a.transport.relayStatus, "disabled")
        a.settings.setEnabled(true)
        wait("reconnecting through the relay") { a.transport.relayedDeviceIds.contains(b.deviceId) }
    }
}
