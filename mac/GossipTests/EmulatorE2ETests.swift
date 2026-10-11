import XCTest
import CryptoKit
import Network
@testable import Gossip

/// End-to-end test of the Mac app's real `TransportManager` (real `NWConnection` sockets, the Rust engine) against the Android
/// app's real `TransportManager` running on an emulator (`TransportE2eTest`, an instrumentation test in the app process,
/// so ART, bionic and JNA are all in the loop). Both sides use throwaway identities and trust stores: this test host reads
/// no Keychain items (see `ProductionBlobStore`) and the emulator is a fresh device.
///
/// Skipped unless `GOSSIP_E2E_ADB_SERIAL` is set; run it with `scripts/e2e-emulator.sh`, which boots the emulator, installs
/// both APKs and passes the environment through (`TEST_RUNNER_` prefixed variables reach the test process).
///
/// The Mac plays the device showing the pairing QR and the Android side scans it, as in the real flow. The Mac then drives
/// the script (ping/pong with nested Unicode payloads, a 1 MB payload, raw follow-up frames both ways, per-feature gating,
/// a heartbeat soak longer than the 60 s stale timeout, disconnect and reconnect with no prompt, revocation) and asserts on
/// everything it receives; the Android side answers and reports its own state on request.
final class EmulatorE2ETests: XCTestCase {
    private let lock = NSLock()
    private var inbox: [Envelope] = []
    private var raws: [(Envelope, Data)] = []
    private var prompts: [(peer: HandshakePeerInfo, key: Curve25519.KeyAgreement.PublicKey)] = []

    private var adbPath: String { ProcessInfo.processInfo.environment["GOSSIP_E2E_ADB"] ?? "/opt/homebrew/share/android-commandlinetools/platform-tools/adb" }

    // MARK: - Helpers

    @discardableResult
    private func adb(_ serial: String, _ arguments: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adbPath)
        p.arguments = ["-s", serial] + arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Spins the main run loop (several callbacks hop to main) until `condition` holds.
    private func wait(_ what: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for \(what)", file: file, line: line); return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func received(_ type: String) -> [Envelope] {
        lock.lock(); defer { lock.unlock() }
        return inbox.filter { $0.type == type }
    }

    private func waitForMessage(_ type: String, after count: Int = 0, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) -> Envelope? {
        wait("a \(type) message", timeout: timeout, file: file, line: line) { received(type).count > count }
        return received(type).dropFirst(count).first
    }

    private func pause(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    }

    private func query(_ transport: TransportManager, _ android: String) throws -> JSONValue {
        let before = received("e2e.state").count
        try transport.send(envelope: Envelope(type: "e2e.query", senderId: IdentityKeyStore.shared.deviceId, recipientId: android))
        return try XCTUnwrap(waitForMessage("e2e.state", after: before)).payload
    }

    private func strings(_ value: JSONValue?) -> [String] {
        guard case .array(let items)? = value else { return [] }
        return items.compactMap(\.stringValue)
    }

    // MARK: - The test

    func testMacAgainstAndroidEmulator() throws {
        guard let serial = ProcessInfo.processInfo.environment["GOSSIP_E2E_ADB_SERIAL"] else {
            throw XCTSkip("set GOSSIP_E2E_ADB_SERIAL (see scripts/e2e-emulator.sh) to run the emulator end-to-end test")
        }
        let identity = IdentityKeyStore.shared
        let trusted = TrustedDevicesStore.shared
        let myPublic = identity.agreementKey.publicKey.rawRepresentation

        let transport = TransportManager()
        let roster = RosterGossipManager(transportManager: transport)
        transport.router.register(prefix: "e2e.") { [weak self] envelope in
            self?.lock.lock(); self?.inbox.append(envelope); self?.lock.unlock()
        }
        transport.onRawFrameReceived = { [weak self] envelope, data in
            self?.lock.lock(); self?.raws.append((envelope, data)); self?.lock.unlock()
        }
        transport.onUntrustedHandshake = { [weak self] peer, key, confirm in
            self?.lock.lock(); self?.prompts.append((peer, key)); self?.lock.unlock()
            confirm(true)
        }

        // ---- Bring the Mac up as the device showing the QR. ----
        let token = UUID().uuidString
        transport.armPairing(token: token)
        transport.start(deviceName: "E2E Mac")
        wait("the listener") { transport.listeningPort != nil }
        let macPort = try XCTUnwrap(transport.listeningPort)

        // The Android side dials the Mac at 10.0.2.2; the Mac reaches the emulator's listener through an adb forward.
        let forward = try adb(serial, ["forward", "tcp:0", "tcp:7913"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let forwardedPort = try XCTUnwrap(UInt16(forward), "adb forward gave: \(forward)")
        defer { _ = try? adb(serial, ["forward", "--remove", "tcp:\(forwardedPort)"]) }

        // ---- Start the Android instrumentation: it scans our QR and then serves the script. ----
        // One quoted command string: the device shell would otherwise split a value like "E2E Mac" at the space.
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var command = "am instrument -w -r -e class dev.vmd1.gossip.e2e.TransportE2eTest"
        for (key, value) in [
            ("mac_id", identity.deviceId), ("mac_name", "E2E Mac"), ("mac_port", "\(macPort)"), ("token", token),
            ("mac_noise_pub", myPublic.base64EncodedString()),
            ("mac_signing_pub", identity.signingKey.publicKey.rawRepresentation.base64EncodedString()),
        ] { command += " -e \(key) \(quoted(value))" }
        command += " dev.vmd1.gossip.test/androidx.test.runner.AndroidJUnitRunner"
        let arguments = ["shell", command]
        let instrument = Process()
        instrument.executableURL = URL(fileURLWithPath: adbPath)
        instrument.arguments = ["-s", serial] + arguments
        let instrumentOut = Pipe()
        instrument.standardOutput = instrumentOut
        instrument.standardError = instrumentOut
        var instrumentLog = Data()
        instrumentOut.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            self?.lock.lock(); instrumentLog.append(chunk); self?.lock.unlock()
        }
        try instrument.run()
        defer {
            if instrument.isRunning { instrument.terminate() }
            transport.stop()
            // Whatever happened, show what the Android side saw.
            let logcat = (try? adb(serial, ["logcat", "-d", "-s", "E2E"])) ?? ""
            lock.lock(); let output = String(decoding: instrumentLog, as: UTF8.self); lock.unlock()
            print("---- Android E2E log ----\n\(logcat)\n---- instrumentation output ----\n\(output)")
        }

        // ---- 1. Pairing: the user is asked once, both sides show the same code, and trust is persisted. ----
        wait("the Android device to connect and say hello", timeout: 90) { !received("e2e.hello").isEmpty }
        let hello = try XCTUnwrap(received("e2e.hello").first)
        let androidId = try XCTUnwrap(hello.payload["deviceId"]?.stringValue)
        XCTAssertEqual(prompts.count, 1, "exactly one confirmation prompt")
        XCTAssertEqual(prompts.first?.peer.deviceId, androidId)
        let androidNoisePub = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(hello.payload["noisePublicKey"]?.stringValue)))
        XCTAssertEqual(prompts.first?.key.rawRepresentation, androidNoisePub, "the key the handshake authenticated is the one the device reports")
        XCTAssertEqual(hello.payload["pairingCode"]?.stringValue, PairingCode.make(myPublic, androidNoisePub), "both screens show the same code")
        wait("the connection to be live") { transport.connectedDeviceIds.contains(androidId) }
        let row = try XCTUnwrap(trusted.device(for: androidId))
        XCTAssertEqual(row.publicKeyBase64, androidNoisePub.base64EncodedString())
        XCTAssertEqual(row.signingPublicKeyBase64, hello.payload["signingPublicKey"]?.stringValue, "the signing key came from the authenticated handshake")
        XCTAssertEqual(row.deviceType, .androidPhone)

        let state0 = try query(transport, androidId)
        XCTAssertEqual(strings(state0["connected"]), [identity.deviceId])
        XCTAssertTrue(strings(state0["trusted"]).contains(identity.deviceId), "the Android side trusts the Mac")
        XCTAssertEqual(state0["macHasSigningKey"]?.boolValue, true)

        // ---- 2. Messages: nested Unicode, a 1 MB payload, ids and signatures intact. ----
        let nested: JSONValue = .object([
            "title": .string("Héllo \"q\" \\ 日本 😀"), "n": .number(9_007_199_254_740_991), "neg": .number(-3),
            "list": .array([.number(1), .string("x"), .object(["k": .array([])]), .null, .bool(false)]),
        ])
        var pongs = 0
        try transport.send(envelope: Envelope(type: "e2e.ping", senderId: identity.deviceId, recipientId: androidId, payload: nested))
        var pong = try XCTUnwrap(waitForMessage("e2e.pong", after: pongs)); pongs += 1
        XCTAssertEqual(pong.payload["title"], nested["title"])
        XCTAssertEqual(pong.payload["list"], nested["list"])
        XCTAssertEqual(pong.payload["n"], nested["n"])
        XCTAssertEqual(pong.payload["seenBy"]?.stringValue, "android")
        XCTAssertNotNil(pong.sig, "the Android engine signed it and ours verified it")

        let big = String(repeating: "0123456789abcdef", count: 65_536) // 1 MiB
        try transport.send(envelope: Envelope(type: "e2e.ping", senderId: identity.deviceId, recipientId: androidId, payload: .object(["big": .string(big)])))
        pong = try XCTUnwrap(waitForMessage("e2e.pong", after: pongs, timeout: 30)); pongs += 1
        XCTAssertEqual(pong.payload["big"]?.stringValue?.count, big.count)

        // ---- 3. Raw follow-up frames, both directions. ----
        let raw = Data((0..<(3 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 2654435761 >> 7) })
        let rawEnvelope = Envelope(type: "e2e.raw", senderId: identity.deviceId, recipientId: androidId, hasRawFollowup: true, payload: .object([:]))
        try transport.send(rawEnvelope, withRawFollowup: raw)
        let rawHash = try XCTUnwrap(waitForMessage("e2e.rawhash", timeout: 30))
        XCTAssertEqual(rawHash.payload["sha256"]?.stringValue, Data(SHA256.hash(data: raw)).base64EncodedString())
        XCTAssertEqual(rawHash.payload["size"]?.numberValue, Double(raw.count))
        XCTAssertEqual(rawHash.payload["forId"]?.stringValue, rawEnvelope.id)

        try transport.send(envelope: Envelope(type: "e2e.sendraw", senderId: identity.deviceId, recipientId: androidId, payload: .object(["size": .number(200_000)])))
        wait("the raw frame from Android", timeout: 30) { lock.lock(); defer { lock.unlock() }; return raws.contains { $0.0.type == "e2e.rawfromandroid" } }
        lock.lock(); let fromAndroid = raws.first { $0.0.type == "e2e.rawfromandroid" }; lock.unlock()
        XCTAssertEqual(fromAndroid?.1, Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }), "the raw frame arrives intact with its envelope")

        // ---- 4. Per-feature gating on the Android side. ----
        func send(_ type: String) throws {
            try transport.send(envelope: Envelope(type: type, senderId: identity.deviceId, recipientId: androidId, payload: .object(["enabled": .bool(true)])))
        }
        try send("dnd.update"); try send("clipboard.update")
        pause(1)
        var state = try query(transport, androidId)
        XCTAssertEqual(state["dnd"]?.numberValue, 1); XCTAssertEqual(state["clipboard"]?.numberValue, 1)
        try transport.send(envelope: Envelope(type: "e2e.disable", senderId: identity.deviceId, recipientId: androidId, payload: .object(["keys": .array([.string("clipboard")])])))
        pause(1)
        try send("dnd.update"); try send("clipboard.update")
        pause(1)
        state = try query(transport, androidId)
        XCTAssertEqual(state["dnd"]?.numberValue, 2, "dnd still delivered")
        XCTAssertEqual(state["clipboard"]?.numberValue, 1, "clipboard dropped by the engine while its feature is off")
        try transport.send(envelope: Envelope(type: "e2e.disable", senderId: identity.deviceId, recipientId: androidId, payload: .object(["keys": .array([])])))
        pause(1)
        try send("clipboard.update"); pause(1)
        state = try query(transport, androidId)
        XCTAssertEqual(state["clipboard"]?.numberValue, 2, "re-enabling takes effect")

        // ---- 5. Heartbeats: both sides must still be connected well past the 60 s stale timeout. ----
        pause(70)
        XCTAssertTrue(transport.connectedDeviceIds.contains(androidId), "still connected after 70 s idle (heartbeats flowing both ways)")
        state = try query(transport, androidId)
        XCTAssertEqual(strings(state["connected"]), [identity.deviceId])

        // ---- 6. Disconnect, then reconnect from the Mac with no prompt. ----
        transport.disconnect(deviceId: androidId)
        wait("the disconnect") { !transport.connectedDeviceIds.contains(androidId) }
        let androidKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: androidNoisePub)
        transport.connect(toFallbackHost: "127.0.0.1", port: NWEndpointPort(forwardedPort), remoteStaticKey: androidKey, deviceId: androidId)
        wait("the reconnect", timeout: 30) { transport.connectedDeviceIds.contains(androidId) }
        XCTAssertEqual(prompts.count, 1, "a reconnect of a trusted device asks nobody")
        state = try query(transport, androidId)
        XCTAssertEqual(strings(state["connected"]), [identity.deviceId], "the Android side sees the new connection")

        // ---- 7. Revocation: the Mac forgets the device; the Android side then cannot get back in. ----
        try transport.send(envelope: Envelope(type: "e2e.finish", senderId: identity.deviceId, recipientId: androidId))
        pause(1)
        roster.revoke(deviceId: androidId)
        wait("the revoked device to be dropped") { !transport.connectedDeviceIds.contains(androidId) }
        XCTAssertFalse(trusted.isTrusted(deviceId: androidId))
        XCTAssertNotNil(trusted.revokedAt(deviceId: androidId))
        pause(14) // the Android test dials us again during this window
        XCTAssertFalse(transport.connectedDeviceIds.contains(androidId), "a revoked device cannot reconnect")
        XCTAssertEqual(prompts.count, 1, "and is never offered to the user again without a new pairing")

        // ---- The Android side's own assertions. ----
        wait("the instrumentation to finish", timeout: 60) { !instrument.isRunning }
        instrumentOut.fileHandleForReading.readabilityHandler = nil
        lock.lock(); let output = String(decoding: instrumentLog, as: UTF8.self); lock.unlock()
        XCTAssertTrue(output.contains("OK (2 tests)"), "the Android side passed its own checks:\n\(output)")
    }
}

private func NWEndpointPort(_ value: UInt16) -> NWEndpoint.Port { NWEndpoint.Port(rawValue: value)! }
