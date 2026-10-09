import XCTest
import CryptoKit
import Combine
import Network
@testable import Gossip

/// Cross-device end-to-end test of the relay: the Mac app's real `TransportManager` against the Android app's real
/// `TransportManager` on an emulator (`RelayE2eTest`, an instrumentation test), where the two can talk to each other ONLY
/// through a real relay server (`relay/`, started and stopped by this test) over real WebSockets (`RelayConnection` on the
/// Mac, OkHttp on Android). Both sides use throwaway identities, trust stores and topic storage.
///
/// Flow: pair over the LAN-style path (the emulator dials the Mac at 10.0.2.2, as in `EmulatorE2ETests`), which creates the
/// mesh topic and distributes it with `mesh.topic`; turn the relay on at both ends; take the LAN away from both (the Android
/// listener stops, the link is dropped, nobody dials); watch them reconnect through the relay; exercise the relayed link;
/// bring the LAN back and check it replaces the relay link silently; then kill and restart the relay.
///
/// Both sides use the same relay address, `ws://127.0.0.1:<port>`, because the origin string is signed into every join:
/// `adb reverse` maps the emulator's 127.0.0.1:<port> to this Mac's relay.
///
/// Skipped unless `GOSSIP_E2E_ADB_SERIAL` and `GOSSIP_E2E_RELAY_DIR` are set; run it with `scripts/e2e-relay-emulator.sh`.
final class EmulatorRelayE2ETests: XCTestCase {
    private let lock = NSLock()
    private var inbox: [Envelope] = []
    private var raws: [(Envelope, Data)] = []
    private var prompts = 0
    private var restricted = 0

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

    private func wait(_ what: String, timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for \(what)", file: file, line: line); return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func pause(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    }

    private func received(_ type: String) -> [Envelope] {
        lock.lock(); defer { lock.unlock() }
        return inbox.filter { $0.type == type }
    }

    private func waitForMessage(_ type: String, after count: Int = 0, timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line) -> Envelope? {
        wait("a \(type) message", timeout: timeout, file: file, line: line) { received(type).count > count }
        return received(type).dropFirst(count).first
    }

    private func strings(_ value: JSONValue?) -> [String] {
        guard case .array(let items)? = value else { return [] }
        return items.compactMap(\.stringValue)
    }

    /// The local relay server, as a child process we can kill and start again on the same port.
    private final class RelayServer {
        let port: Int
        private let directory: String
        private let node: String
        private var process: Process?
        init(port: Int, directory: String, node: String) { self.port = port; self.directory = directory; self.node = node }

        func start() throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: node)
            p.arguments = ["dist/src/relay.js"]
            p.currentDirectoryURL = URL(fileURLWithPath: directory)
            var environment = ProcessInfo.processInfo.environment
            environment["HOST"] = "127.0.0.1"
            environment["PORT"] = "\(port)"
            environment["POW_BITS"] = "8"
            environment["RELAY_ORIGIN"] = "ws://127.0.0.1:\(port)"
            environment["LOG_LEVEL"] = "warn"
            p.environment = environment
            p.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
            p.standardError = FileHandle(forWritingAtPath: "/dev/null")
            try p.run()
            process = p
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if Self.accepting(port) { return }
                Thread.sleep(forTimeInterval: 0.1)
            }
            throw NSError(domain: "relay", code: 1, userInfo: [NSLocalizedDescriptionKey: "the relay did not start"])
        }

        func stop() {
            process?.terminate()
            process?.waitUntilExit()
            process = nil
        }

        private static func accepting(_ port: Int) -> Bool {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(fd) }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(port).bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
            }
        }
    }

    // MARK: - The test

    func testMacAndAndroidTalkOnlyThroughTheRelay() throws {
        let env = ProcessInfo.processInfo.environment
        guard let serial = env["GOSSIP_E2E_ADB_SERIAL"], let relayDir = env["GOSSIP_E2E_RELAY_DIR"], let node = env["GOSSIP_E2E_NODE"],
              let portText = env["GOSSIP_E2E_RELAY_PORT"], let relayPort = Int(portText) else {
            throw XCTSkip("set GOSSIP_E2E_ADB_SERIAL and friends (see scripts/e2e-relay-emulator.sh) to run the Mac-Android relay test")
        }
        let origin = "ws://127.0.0.1:\(relayPort)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-emu-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // ---- The relay, reachable from the emulator at the same address. ----
        let relay = RelayServer(port: relayPort, directory: relayDir, node: node)
        try relay.start()
        defer { relay.stop() }
        try adb(serial, ["reverse", "tcp:\(relayPort)", "tcp:\(relayPort)"])
        defer { _ = try? adb(serial, ["reverse", "--remove", "tcp:\(relayPort)"]) }

        // ---- The Mac side: shared throwaway identity and trust (this test host reads no Keychain), private relay settings. ----
        let identity = IdentityKeyStore.shared
        let trusted = TrustedDevicesStore.shared
        let myPublic = identity.agreementKey.publicKey.rawRepresentation
        let settings = RelaySettings(defaults: UserDefaults(suiteName: "RelayEmuE2E-\(UUID().uuidString)")!)
        settings.setCustomURL(origin)
        let topics = RelayTopicStore(blob: FileBlobStore(url: directory.appendingPathComponent("mac-topic.json")))
        let transport = TransportManager(trustedDevices: trusted, identity: identity, relaySettings: settings, topicStore: topics)
        transport.setLanGraceMs(1_000)
        transport.router.register(prefix: "e2e.") { [weak self] envelope in
            self?.lock.lock(); self?.inbox.append(envelope); self?.lock.unlock()
        }
        for prefix in ["screen.", "control."] {
            transport.router.register(prefix: prefix) { [weak self] _ in self?.lock.lock(); self?.restricted += 1; self?.lock.unlock() }
        }
        transport.onRawFrameReceived = { [weak self] envelope, data in
            self?.lock.lock(); self?.raws.append((envelope, data)); self?.lock.unlock()
        }
        transport.onUntrustedHandshake = { [weak self] _, _, confirm in
            self?.lock.lock(); self?.prompts += 1; self?.lock.unlock()
            confirm(true)
        }

        let token = UUID().uuidString
        transport.armPairing(token: token)
        transport.start(deviceName: "E2E Mac")
        wait("the listener") { transport.listeningPort != nil }
        let macPort = try XCTUnwrap(transport.listeningPort)

        // The Mac reaches the emulator's LAN listener through an adb forward (the later "LAN comes back" step).
        let forward = try adb(serial, ["forward", "tcp:0", "tcp:7913"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let forwardedPort = try XCTUnwrap(UInt16(forward), "adb forward gave: \(forward)")
        defer { _ = try? adb(serial, ["forward", "--remove", "tcp:\(forwardedPort)"]) }

        // ---- Start the Android instrumentation. ----
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var command = "am instrument -w -r -e class dev.vmd1.gossip.e2e.RelayE2eTest"
        for (key, value) in [
            ("mac_id", identity.deviceId), ("mac_name", "E2E Mac"), ("mac_port", "\(macPort)"), ("token", token),
            ("mac_noise_pub", myPublic.base64EncodedString()),
            ("mac_signing_pub", identity.signingKey.publicKey.rawRepresentation.base64EncodedString()),
        ] { command += " -e \(key) \(quoted(value))" }
        command += " dev.vmd1.gossip.test/androidx.test.runner.AndroidJUnitRunner"
        let instrument = Process()
        instrument.executableURL = URL(fileURLWithPath: adbPath)
        instrument.arguments = ["-s", serial, "shell", command]
        let instrumentOut = Pipe()
        instrument.standardOutput = instrumentOut
        instrument.standardError = instrumentOut
        var instrumentLog = Data()
        instrumentOut.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            self?.lock.lock(); instrumentLog.append(chunk); self?.lock.unlock()
        }
        try instrument.run()

        // What the Mac's own connection state did: it must never lose the Android device while the LAN replaces the relay.
        var reachability: [Bool] = []
        var androidIdForWatch: String?
        let watch = Publishers.CombineLatest(transport.$connectedDeviceIds, transport.$relayedDeviceIds).sink { direct, relayed in
            guard let id = androidIdForWatch else { return }
            reachability.append(direct.contains(id) || relayed.contains(id))
        }
        defer {
            watch.cancel()
            if instrument.isRunning { instrument.terminate() }
            transport.stop()
            let logcat = (try? adb(serial, ["logcat", "-d", "-s", "E2E", "TransportManager", "RelayConnection"])) ?? ""
            lock.lock(); let output = String(decoding: instrumentLog, as: UTF8.self); lock.unlock()
            print("---- Android E2E log ----\n\(logcat)\n---- instrumentation output ----\n\(output)")
        }

        func query() throws -> JSONValue {
            let before = received("e2e.state").count
            try transport.send(envelope: Envelope(type: "e2e.query", senderId: identity.deviceId, recipientId: androidId))
            return try XCTUnwrap(waitForMessage("e2e.state", after: before)).payload
        }
        func say(_ type: String, _ payload: JSONValue = .object([:])) throws {
            try transport.send(envelope: Envelope(type: type, senderId: identity.deviceId, recipientId: androidId, payload: payload))
        }

        // ---- 1. Pair over the LAN-style path. This first connection creates the mesh topic. ----
        wait("the Android device to connect and say hello", timeout: 90) { !received("e2e.hello").isEmpty }
        let hello = try XCTUnwrap(received("e2e.hello").first)
        androidId = try XCTUnwrap(hello.payload["deviceId"]?.stringValue)
        let androidNoisePub = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(hello.payload["noisePublicKey"]?.stringValue)))
        XCTAssertEqual(prompts, 1)
        wait("the LAN connection") { transport.connectedDeviceIds.contains(androidId) }
        XCTAssertEqual(transport.connectionPath(for: androidId), .direct)
        XCTAssertEqual(transport.relayStatus, "disabled", "the relay is opt-in: nothing is open yet")

        // ---- 2. The topic exists on both sides and is the same one (created once, distributed by mesh.topic). ----
        wait("the Mac to persist the mesh topic") { topics.load() != nil }
        var state = try query()
        wait("the Android side to persist the mesh topic", timeout: 20) { (try? query())?["topicSaved"]?.boolValue == true }
        state = try query()
        XCTAssertEqual(state["topicSecretB64"]?.stringValue, topics.load()?.secret.base64EncodedString(), "both devices hold the same topic secret")
        XCTAssertEqual(state["isRelayed"]?.boolValue, false)
        androidIdForWatch = androidId

        // ---- 3. Relay on at both ends, then the LAN goes away for both. ----
        try say("e2e.relay_on", .object(["origin": .string(origin)]))
        settings.setEnabled(true)
        pause(2)
        try say("e2e.lan_off")           // Android: stop listening and drop the direct link
        transport.disconnect(deviceId: androidId)
        wait("the LAN link to go away") { !transport.connectedDeviceIds.contains(androidId) }

        // ---- 4. They find each other through the relay, with no LAN dial from anyone. ----
        wait("the Mac to reach Android through the relay", timeout: 90) { transport.relayedDeviceIds.contains(androidId) }
        XCTAssertEqual(transport.connectionPath(for: androidId), .relayed)
        XCTAssertTrue(transport.isRelayed(androidId))
        XCTAssertFalse(transport.connectedDeviceIds.contains(androidId), "relayed is not a same-network connection")
        XCTAssertEqual(transport.relayStatus, "joined")
        XCTAssertEqual(prompts, 1, "no prompt: the devices were already trusted")
        state = try query()
        XCTAssertEqual(state["isRelayed"]?.boolValue, true, "Android sees the Mac as relayed too")
        XCTAssertEqual(strings(state["relayed"]), [identity.deviceId])
        XCTAssertEqual(strings(state["direct"]), [])
        XCTAssertEqual(state["relayStatus"]?.stringValue, "joined")

        // ---- 5. A 1 MiB payload both ways, and 2 MiB raw frames both ways. ----
        let big = String(repeating: "0123456789abcdef", count: 65_536)
        try say("e2e.ping", .object(["big": .string(big), "title": .string("Héllo 日本 😀")]))
        let pong = try XCTUnwrap(waitForMessage("e2e.pong", timeout: 60))
        XCTAssertEqual(pong.payload["big"]?.stringValue?.count, big.count)
        XCTAssertEqual(pong.payload["title"]?.stringValue, "Héllo 日本 😀")
        XCTAssertEqual(pong.payload["seenBy"]?.stringValue, "android")
        XCTAssertNotNil(pong.sig)

        let raw = Data((0..<(2 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 2654435761 >> 7) })
        let rawEnvelope = Envelope(type: "e2e.raw", senderId: identity.deviceId, recipientId: androidId, hasRawFollowup: true, payload: .object([:]))
        try transport.send(rawEnvelope, withRawFollowup: raw)
        let rawHash = try XCTUnwrap(waitForMessage("e2e.rawhash", timeout: 60))
        XCTAssertEqual(rawHash.payload["sha256"]?.stringValue, Data(SHA256.hash(data: raw)).base64EncodedString())
        XCTAssertEqual(rawHash.payload["forId"]?.stringValue, rawEnvelope.id)

        let rawSize = 2 * 1024 * 1024
        try say("e2e.sendraw", .object(["size": .number(Double(rawSize))]))
        wait("the raw frame from Android", timeout: 60) { lock.lock(); defer { lock.unlock() }; return raws.contains { $0.0.type == "e2e.rawfromandroid" } }
        lock.lock(); let fromAndroid = raws.first { $0.0.type == "e2e.rawfromandroid" }; lock.unlock()
        XCTAssertEqual(fromAndroid?.1, Data((0..<rawSize).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }))

        // ---- 6. screen.* and control.* never cross the relay, in either direction. ----
        for type in ["screen.start", "control.session_start"] {
            XCTAssertThrowsError(try say(type), "\(type) must be refused over a relayed link")
        }
        try say("e2e.sendscreen")
        pause(2)
        state = try query()
        XCTAssertEqual(state["screenSendThrew"]?.numberValue, 2, "Android refused to send both")
        XCTAssertEqual(state["screenDelivered"]?.numberValue, 0)
        lock.lock(); XCTAssertEqual(restricted, 0, "nothing restricted reached the Mac"); lock.unlock()

        // ---- 7. The LAN comes back: it replaces the relay link with no prompt and no disconnect on either side. ----
        let dropsBefore = try XCTUnwrap(state["peerDrops"]?.numberValue)
        let macSawBefore = reachability.count
        try say("e2e.lan_on")
        pause(2)
        let androidKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: androidNoisePub)
        // Retry the dial: the Mac's own Bonjour redial of the emulator's unreachable advertised address can hold the per-device
        // dial slot for up to 15 s, in which case a manual dial is skipped.
        let lanDeadline = Date().addingTimeInterval(60)
        while !transport.connectedDeviceIds.contains(androidId) && Date() < lanDeadline {
            transport.connect(toFallbackHost: "127.0.0.1", port: NWEndpointPort(forwardedPort), remoteStaticKey: androidKey, deviceId: androidId)
            pause(3)
        }
        wait("the LAN link to replace the relay link", timeout: 5) { transport.connectedDeviceIds.contains(androidId) && !transport.relayedDeviceIds.contains(androidId) }
        XCTAssertEqual(transport.connectionPath(for: androidId), .direct)
        XCTAssertEqual(prompts, 1, "the LAN reconnect asks nobody")
        XCTAssertFalse(reachability.dropFirst(macSawBefore).contains(false), "the Mac never lost the device while the LAN replaced the relay")
        state = try query()
        XCTAssertEqual(state["isRelayed"]?.boolValue, false)
        XCTAssertEqual(strings(state["direct"]), [identity.deviceId])
        XCTAssertEqual(state["peerDrops"]?.numberValue, dropsBefore, "Android saw no disconnect")

        // ---- 8. With every device on the LAN, Android parks its relay socket (battery); the Mac keeps its own. ----
        wait("Android to park the relay", timeout: 60) { (try? query())?["relayIdle"]?.boolValue == true }
        state = try query()
        XCTAssertEqual(state["relayStatus"]?.stringValue, "disabled")

        // ---- 9. The LAN goes away again: the relay is switched back on and reconnects. ----
        try say("e2e.lan_off")
        transport.disconnect(deviceId: androidId)
        wait("the reconnect through the relay", timeout: 90) { transport.relayedDeviceIds.contains(androidId) }
        state = try query()
        XCTAssertEqual(state["isRelayed"]?.boolValue, true)
        XCTAssertEqual(state["relayIdle"]?.boolValue, false)

        // ---- 10. Kill the relay: both sides lose each other. Restart it: they come back. ----
        relay.stop()
        wait("the relayed peer to go away when the relay dies", timeout: 60) { !transport.relayedDeviceIds.contains(androidId) }
        XCTAssertNotEqual(transport.relayStatus, "joined")
        try relay.start()
        wait("the reconnect after the relay restarts", timeout: 120) { transport.relayedDeviceIds.contains(androidId) }
        state = try query()
        XCTAssertEqual(state["isRelayed"]?.boolValue, true)
        try say("e2e.ping", .object(["after": .string("restart")]))
        _ = try XCTUnwrap(waitForMessage("e2e.pong", after: 1, timeout: 30))

        // ---- Android's own assertions. ----
        try say("e2e.finish")
        wait("the instrumentation to finish", timeout: 60) { !instrument.isRunning }
        instrumentOut.fileHandleForReading.readabilityHandler = nil
        lock.lock(); let output = String(decoding: instrumentLog, as: UTF8.self); lock.unlock()
        XCTAssertTrue(output.contains("OK (1 test)"), "the Android side passed its own checks:\n\(output)")
    }

    private var androidId: String = ""
}

private func NWEndpointPort(_ value: UInt16) -> NWEndpoint.Port { NWEndpoint.Port(rawValue: value)! }
