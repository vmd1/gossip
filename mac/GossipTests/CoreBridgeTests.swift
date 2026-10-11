import XCTest
import CryptoKit
@testable import Gossip

/// Drives two real Rust engines through `CoreBridge`, wired together in memory, to check everything the app relies on
/// that is not protocol logic (that is tested in `desktop/core`): envelope and payload conversion, the trust snapshot
/// round trip into `TrustedDevicesStore`, and the pairing, reconnect and revocation flows as the app sees them.
final class CoreBridgeTests: XCTestCase {
    private final class Peer {
        let name: String
        let identity: IdentityKeyStore
        let trust: TrustedDevicesStore
        let bridge: CoreBridge
        var events: [CoreBridge.BridgeAction] = []

        init(_ name: String, directory: URL, disabledFeatures: [String] = []) throws {
            self.name = name
            identity = IdentityKeyStore(fileURL: directory.appendingPathComponent("\(name)-identity.json"))
            trust = TrustedDevicesStore(fileURL: directory.appendingPathComponent("\(name)-trusted.json"))
            bridge = try CoreBridge(identity: identity, deviceName: name, trustedDevices: trust, disabledFeatures: disabledFeatures)
        }

        var deviceId: String { identity.deviceId }
        var noisePublicKey: Data { identity.agreementKey.publicKey.rawRepresentation }

        func delivered(_ type: String) -> [Envelope] {
            events.compactMap { if case .deliver(let e, _) = $0, e.type == type { return e } else { return nil } }
        }

        func prompt() -> (conn: UInt64, peer: HandshakePeerInfo, key: Curve25519.KeyAgreement.PublicKey)? {
            for case .pairingPrompt(let conn, let peer, let key) in events.reversed() { return (conn, peer, key) }
            return nil
        }
    }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Two peers and the in-memory links between them.
    private final class Wire {
        var links: [String: (Peer, UInt64)] = [:]
        var next: UInt64 = 1

        func pump(_ origin: Peer, _ actions: [CoreBridge.BridgeAction]) {
            var queue = actions.map { (origin, $0) }
            while !queue.isEmpty {
                let (peer, action) = queue.removeFirst()
                switch action {
                case .send(let conn, let bytes):
                    if let (other, otherConn) = links["\(peer.name):\(conn)"] {
                        queue += other.bridge.bytesReceived(conn: otherConn, bytes).map { (other, $0) }
                    }
                case .close(let conn):
                    if let (other, otherConn) = links.removeValue(forKey: "\(peer.name):\(conn)") {
                        links.removeValue(forKey: "\(other.name):\(otherConn)")
                        queue += other.bridge.connectionClosed(conn: otherConn).map { (other, $0) }
                    }
                case .trustChanged(let json):
                    peer.trust.importCoreSnapshot(json)
                    peer.events.append(action)
                default:
                    peer.events.append(action)
                }
            }
        }

        func open(dialer: Peer, listener: Peer, pairingToken: String? = nil) throws {
            let (a, b) = (next, next + 1)
            next += 2
            links["\(dialer.name):\(a)"] = (listener, b)
            links["\(listener.name):\(b)"] = (dialer, a)
            pump(listener, try listener.bridge.accepted(conn: b))
            pump(dialer, try dialer.bridge.dial(conn: a, target: listener.deviceId, remoteStaticKey: listener.noisePublicKey, pairingToken: pairingToken))
        }
    }

    /// The scan-and-confirm flow: the device showing the QR arms a token, the scanner dials it presenting that token,
    /// and the user confirms on both screens (each is shown the same six digits).
    private func pair(_ wire: Wire, shower: Peer, scanner: Peer) throws {
        shower.bridge.armPairing(token: "token-1")
        try wire.open(dialer: scanner, listener: shower, pairingToken: "token-1")
        let showerPrompt = try XCTUnwrap(shower.prompt(), "the device showing the QR must be asked to confirm")
        let scannerPrompt = try XCTUnwrap(scanner.prompt(), "the scanner confirms too")
        XCTAssertEqual(showerPrompt.peer.deviceId, scanner.deviceId)
        XCTAssertEqual(PairingCode.make(shower.noisePublicKey, showerPrompt.key.rawRepresentation),
                       PairingCode.make(scanner.noisePublicKey, scannerPrompt.key.rawRepresentation), "both screens show the same code")
        wire.pump(shower, shower.bridge.confirmPairing(conn: showerPrompt.conn, accepted: true))
        wire.pump(scanner, scanner.bridge.confirmPairing(conn: scannerPrompt.conn, accepted: true))
    }

    func testPairingDeliversMessagesWithPayloadsIntact() throws {
        let wire = Wire()
        let mac = try Peer("mac", directory: directory), phone = try Peer("phone", directory: directory)
        try pair(wire, shower: mac, scanner: phone)
        XCTAssertTrue(phone.bridge.isConnected(deviceId: mac.deviceId))
        XCTAssertTrue(mac.bridge.isConnected(deviceId: phone.deviceId))

        let payload: JSONValue = .object([
            "title": .string("Héllo \"q\" \\ 日本 😀"), "count": .number(42), "big": .number(9_007_199_254_740_991), "neg": .number(-7),
            "flag": .bool(true), "nothing": .null, "list": .array([.number(1), .string("two"), .object(["k": .array([])])]),
        ])
        let sent = Envelope(type: "notification.posted", senderId: phone.deviceId, broadcast: true, payload: payload)
        wire.pump(phone, try phone.bridge.send(sent))

        let received = try XCTUnwrap(mac.delivered("notification.posted").first)
        XCTAssertEqual(received.payload, payload, "payload survives the trip through the engine exactly")
        XCTAssertEqual(received.senderId, phone.deviceId)
        XCTAssertEqual(received.id, sent.id)
        XCTAssertNotNil(received.sig, "the engine signed it")
        XCTAssertTrue(received.broadcast)
    }

    func testRawFollowupArrivesWithItsEnvelope() throws {
        let wire = Wire()
        let mac = try Peer("mac", directory: directory), phone = try Peer("phone", directory: directory)
        try pair(wire, shower: mac, scanner: phone)
        let png = Data((0..<2000).map { UInt8($0 % 251) })
        let env = Envelope(type: "clipboard.update", senderId: phone.deviceId, broadcast: true, hasRawFollowup: true,
                           payload: .object(["kind": .string("image")]))
        wire.pump(phone, try phone.bridge.send(env, raw: png))
        var raw: Data?
        for case .deliver(let e, let data) in mac.events where e.type == "clipboard.update" { raw = data }
        XCTAssertEqual(raw, png)
    }

    func testTrustSnapshotFlowsIntoTheAppStoreAndSurvivesARestart() throws {
        let wire = Wire()
        let mac = try Peer("mac", directory: directory), phone = try Peer("phone", directory: directory)
        try pair(wire, shower: mac, scanner: phone)

        // The shower learned the scanner through the engine, and the app store got it, with the handshake's signing key.
        let row = try XCTUnwrap(mac.trust.device(for: phone.deviceId))
        XCTAssertEqual(row.publicKeyBase64, phone.noisePublicKey.base64EncodedString())
        XCTAssertEqual(row.signingPublicKeyBase64, phone.identity.signingKey.publicKey.rawRepresentation.base64EncodedString())
        XCTAssertEqual(row.deviceName, "phone")
        XCTAssertEqual(row.deviceType, .mac, "this bridge always identifies itself as a Mac")

        // A restart: fresh engines built from the persisted stores reconnect with no prompt.
        let wire2 = Wire()
        let mac2 = try Peer("mac", directory: directory), phone2 = try Peer("phone", directory: directory)
        try wire2.open(dialer: mac2, listener: phone2)
        XCTAssertNil(mac2.prompt()); XCTAssertNil(phone2.prompt())
        XCTAssertTrue(mac2.bridge.isConnected(deviceId: phone.deviceId))
        XCTAssertTrue(phone2.bridge.isConnected(deviceId: mac.deviceId))
    }

    func testAppOnlyFieldsSurviveEngineSnapshots() throws {
        let wire = Wire()
        let mac = try Peer("mac", directory: directory), phone = try Peer("phone", directory: directory)
        try pair(wire, shower: mac, scanner: phone)
        mac.trust.setFallbackHost(deviceId: phone.deviceId, fallbackHost: "100.64.0.9")
        mac.trust.setLockOnLeaveEnabled(deviceId: phone.deviceId, enabled: true)
        mac.trust.setBeaconKey(deviceId: phone.deviceId, beaconKeyBase64: Data(repeating: 7, count: 32).base64EncodedString())

        // The engine reports another change (a roster introduces a stranger): the existing row keeps its app-only data.
        let stranger = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let strangerId = UUID().uuidString.lowercased()
        let roster = Envelope(type: "trust.roster_update", senderId: phone.deviceId, recipientId: mac.deviceId, payload: .object(["devices": .array([
            .object(["deviceId": .string(strangerId), "publicKey": .string(stranger), "deviceName": .string("Tablet"), "deviceType": .string("android-tablet")])
        ])]))
        wire.pump(phone, try phone.bridge.send(roster))

        XCTAssertNotNil(mac.trust.device(for: strangerId), "gossip introduced the tablet through the engine")
        let kept = try XCTUnwrap(mac.trust.device(for: phone.deviceId))
        XCTAssertEqual(kept.fallbackHost, "100.64.0.9")
        XCTAssertTrue(kept.lockOnLeaveEnabled)
        XCTAssertNotNil(kept.beaconKeyBase64)
    }

    func testRevokingADeviceRemovesItAndLeavesATombstone() throws {
        let wire = Wire()
        let mac = try Peer("mac", directory: directory), phone = try Peer("phone", directory: directory)
        try pair(wire, shower: mac, scanner: phone)
        wire.pump(mac, mac.bridge.revokeDevice(deviceId: phone.deviceId))

        XCTAssertFalse(mac.bridge.isConnected(deviceId: phone.deviceId), "the connection is dropped")
        XCTAssertFalse(mac.trust.isTrusted(deviceId: phone.deviceId), "the app store no longer trusts it")
        XCTAssertNotNil(mac.trust.revokedAt(deviceId: phone.deviceId), "a tombstone keeps gossip from reviving it")
    }

    func testAFeatureTurnedOffNeverReachesTheApp() throws {
        let wire = Wire()
        let mac = try Peer("mac", directory: directory, disabledFeatures: ["clipboard"]), phone = try Peer("phone", directory: directory)
        try pair(wire, shower: mac, scanner: phone)
        wire.pump(phone, try phone.bridge.send(Envelope(type: "clipboard.update", senderId: phone.deviceId, broadcast: true, payload: .object(["kind": .string("text"), "text": .string("x")]))))
        wire.pump(phone, try phone.bridge.send(Envelope(type: "dnd.update", senderId: phone.deviceId, broadcast: true, payload: .object(["enabled": .bool(true)]))))
        XCTAssertTrue(mac.delivered("clipboard.update").isEmpty)
        XCTAssertEqual(mac.delivered("dnd.update").count, 1)
        mac.bridge.setDisabledFeatures([])
        wire.pump(phone, try phone.bridge.send(Envelope(type: "clipboard.update", senderId: phone.deviceId, broadcast: true, payload: .object(["kind": .string("text"), "text": .string("y")]))))
        XCTAssertEqual(mac.delivered("clipboard.update").count, 1, "re-enabling takes effect immediately")
    }

    func testSendingWithNobodyConnectedIsAnError() throws {
        let lonely = try Peer("lonely", directory: directory)
        XCTAssertThrowsError(try lonely.bridge.send(Envelope(type: "dnd.update", senderId: lonely.deviceId, broadcast: true))) {
            XCTAssertEqual($0 as? CoreBridge.BridgeError, .notConnected)
        }
        // A payload the protocol cannot sign (a fraction) is refused rather than sent unsigned.
        let a = try Peer("a", directory: directory), b = try Peer("b", directory: directory)
        let wire = Wire()
        try pair(wire, shower: a, scanner: b)
        XCTAssertThrowsError(try b.bridge.send(Envelope(type: "battery.update", senderId: b.deviceId, broadcast: true, payload: .object(["level": .number(0.5)]))))
    }

    // MARK: - Trust snapshot format

    func testExportAndImportRoundTripKeepsEveryField() throws {
        let store = TrustedDevicesStore(fileURL: directory.appendingPathComponent("rt.json"))
        let key = Data(repeating: 3, count: 32).base64EncodedString()
        store.addDevice(deviceId: "dev-1", publicKeyBase64: key, deviceName: "Pixel", deviceType: .androidPhone, signingPublicKeyBase64: key)
        store.revoke(deviceId: "dev-gone", revokedAt: 1234)

        let json = store.exportCoreSnapshot()
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let rows = try XCTUnwrap(parsed["devices"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["device_id"] as? String, "dev-1")
        XCTAssertEqual(rows.first?["device_type"] as? String, "android-phone")
        XCTAssertEqual((parsed["revoked"] as? [String: Any])?["dev-gone"] as? Int, 1234)

        let other = TrustedDevicesStore(fileURL: directory.appendingPathComponent("rt2.json"))
        XCTAssertTrue(other.importCoreSnapshot(json))
        XCTAssertEqual(other.device(for: "dev-1")?.deviceName, "Pixel")
        XCTAssertEqual(other.revokedAt(deviceId: "dev-gone"), 1234)
        XCTAssertFalse(other.importCoreSnapshot(json), "importing the same snapshot again changes nothing")
    }

    func testImportNeverDeletesARowTheEngineHasNotHeardOfUnlessItIsTombstoned() {
        let store = TrustedDevicesStore(fileURL: directory.appendingPathComponent("keep.json"))
        let key = Data(repeating: 4, count: 32).base64EncodedString()
        store.addDevice(deviceId: "new-row", publicKeyBase64: key, deviceName: "Added after the snapshot", deviceType: .androidTablet)
        store.addDevice(deviceId: "revoked-row", publicKeyBase64: key, deviceName: "Revoked", deviceType: .androidPhone)
        store.importCoreSnapshot(#"{"devices":[],"revoked":{"revoked-row":99}}"#)
        XCTAssertTrue(store.isTrusted(deviceId: "new-row"), "a row the app added after the engine's snapshot survives")
        XCTAssertFalse(store.isTrusted(deviceId: "revoked-row"), "a tombstoned row is removed")
        XCTAssertEqual(store.revokedAt(deviceId: "revoked-row"), 99)
    }

    func testMalformedSnapshotsAreIgnored() {
        let store = TrustedDevicesStore(fileURL: directory.appendingPathComponent("bad.json"))
        XCTAssertFalse(store.importCoreSnapshot("not json"))
        XCTAssertFalse(store.importCoreSnapshot("{}"))
        XCTAssertFalse(store.importCoreSnapshot(#"{"devices":[{"device_id":1}]}"#))
        XCTAssertTrue(store.allDevices().isEmpty)
    }

    // MARK: - Relay

    func testRelayWithoutATopicStaysIdleAndWithOneRequestsAConnection() throws {
        let wire = Wire()
        let mac = try Peer("mac", directory: directory), phone = try Peer("phone", directory: directory)
        XCTAssertEqual(mac.bridge.relayStatus(), "disabled")
        XCTAssertTrue(mac.bridge.relayConfigure(enabled: true, origin: "wss://relay.example.test").isEmpty, "no topic yet: nothing to connect to")
        XCTAssertEqual(mac.bridge.relayStatus(), "no_topic")

        // The first connection between two trusted devices creates the topic and reports it for persisting.
        try pair(wire, shower: mac, scanner: phone)
        var secret: Data?
        var epoch: UInt64?
        for event in mac.events + phone.events { if case .topicChanged(let s, let e) = event { secret = s; epoch = e } }
        XCTAssertEqual(secret?.count, 32)
        XCTAssertEqual(epoch, 1)

        // A restart loads it back, and enabling the relay then asks the shell to open the socket.
        let restarted = try Peer("mac", directory: directory)
        _ = try restarted.bridge.setTopic(secret: try XCTUnwrap(secret), epoch: try XCTUnwrap(epoch))
        let actions = restarted.bridge.relayConfigure(enabled: true, origin: "wss://relay.example.test")
        XCTAssertTrue(actions.contains { if case .relayConnect(let url) = $0 { return url == "wss://relay.example.test/connect" } else { return false } })
        XCTAssertEqual(restarted.bridge.relayStatus(), "connecting")
        XCTAssertFalse(restarted.bridge.isRelayed(deviceId: phone.deviceId))

        // Garbage from the relay is ignored; a socket that dies is reported and the engine backs off.
        _ = restarted.bridge.relaySocketOpened()
        _ = restarted.bridge.relayTextReceived("not json")
        _ = restarted.bridge.relayBinaryReceived(Data([1, 2, 3]))
        _ = restarted.bridge.relaySocketClosed()
        XCTAssertEqual(restarted.bridge.relayStatus(), "disconnected")

        let off = restarted.bridge.relayConfigure(enabled: false, origin: "")
        XCTAssertNotEqual(restarted.bridge.relayStatus(), "joined")
        _ = off
        XCTAssertEqual(restarted.bridge.relayStatus(), "disabled")
    }

    func testSetTopicRejectsAWrongSizeSecret() throws {
        let mac = try Peer("mac", directory: directory)
        XCTAssertThrowsError(try mac.bridge.setTopic(secret: Data(repeating: 1, count: 5), epoch: 1))
    }
}
