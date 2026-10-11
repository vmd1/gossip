import XCTest
import Network
import CryptoKit
@testable import Gossip

/// End-to-end test of pairing by code against the Android app on an emulator (the instrumentation test
/// `CodePairingE2eTest`). Android is the *new* device: it shows a code. This Mac is the already-paired device the code is
/// typed into: a wrong code is refused and counted, then the right one pairs both sides, and the two connect with no prompt.
///
/// Skipped unless `GOSSIP_E2E_ADB_SERIAL` is set; run it with `scripts/e2e-code-pairing.sh`. The emulator is not on the
/// Mac's network, so the Mac reaches it through an adb forward and is told about it directly instead of through Bonjour.
final class EmulatorCodePairingE2ETests: XCTestCase {
    private let lock = NSLock()
    private var events: [TransportManager.CodePairingEvent] = []
    private var adbPath: String { ProcessInfo.processInfo.environment["GOSSIP_E2E_ADB"] ?? "/opt/homebrew/share/android-commandlinetools/platform-tools/adb" }

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

    private func wait(_ what: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for \(what)", file: file, line: line); return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func eventCount() -> Int { lock.lock(); defer { lock.unlock() }; return events.count }
    private func lastEvent() -> TransportManager.CodePairingEvent? { lock.lock(); defer { lock.unlock() }; return events.last }

    private func logLine(_ serial: String, prefix: String) throws -> String? {
        let logcat = try adb(serial, ["logcat", "-d", "-s", "E2E"])
        for line in logcat.split(separator: "\n").reversed() {
            if let range = line.range(of: "E2E     : \(prefix)") ?? line.range(of: "E2E: \(prefix)") {
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    func testTypingTheAndroidCodeIntoTheMacPairsThem() throws {
        guard let serial = ProcessInfo.processInfo.environment["GOSSIP_E2E_ADB_SERIAL"] else {
            throw XCTSkip("set GOSSIP_E2E_ADB_SERIAL (see scripts/e2e-code-pairing.sh) to run the code-pairing end-to-end test")
        }
        let identity = IdentityKeyStore.shared
        let trusted = TrustedDevicesStore.shared
        let transport = TransportManager()
        transport.onCodePairingEvent = { [weak self] event in
            self?.lock.lock(); self?.events.append(event); self?.lock.unlock()
        }
        transport.start(deviceName: "E2E Mac")
        wait("the listener") { transport.listeningPort != nil }

        let forward = try adb(serial, ["forward", "tcp:0", "tcp:7913"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let forwardedPort = try XCTUnwrap(UInt16(forward), "adb forward gave: \(forward)")
        defer { _ = try? adb(serial, ["forward", "--remove", "tcp:\(forwardedPort)"]); transport.stop() }

        // The Android side starts showing a code.
        let instrument = Process()
        instrument.executableURL = URL(fileURLWithPath: adbPath)
        instrument.arguments = ["-s", serial, "shell", "am instrument -w -r -e class dev.vmd1.gossip.e2e.CodePairingE2eTest dev.vmd1.gossip.test/androidx.test.runner.AndroidJUnitRunner"]
        let instrumentOut = Pipe()
        instrument.standardOutput = instrumentOut
        instrument.standardError = instrumentOut
        try instrument.run()
        defer {
            if instrument.isRunning { instrument.terminate() }
            let logcat = (try? adb(serial, ["logcat", "-d", "-s", "E2E"])) ?? ""
            print("---- Android E2E log ----\n\(logcat)")
        }

        var shown: String?
        var androidId: String?
        wait("the Android device to show a code", timeout: 90) {
            shown = try? logLine(serial, prefix: "code=")
            androidId = try? logLine(serial, prefix: "deviceId=")
            return shown != nil && androidId != nil
        }
        let code = try XCTUnwrap(shown)
        let androidDeviceId = try XCTUnwrap(androidId)
        XCTAssertEqual(code.count, 9, "ABCD-EFGH")

        // Tell the Mac where it is (it advertises pair=1 over Bonjour on a real network; the emulator is behind NAT).
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: try XCTUnwrap(NWEndpoint.Port(rawValue: forwardedPort)))
        transport.injectDiscoveredPeerForTesting(DiscoveredPeer(deviceId: androidDeviceId, publicKeyFingerprint: "", endpoint: endpoint, pairing: true))

        // ---- 1. A wrong code is refused, costs the Android side an attempt, and trusts nothing. ----
        let plain = code.replacingOccurrences(of: "-", with: "")
        let wrong = plain.hasPrefix("A") ? "BBBBBBBB" : "AAAAAAAA"
        transport.enterCode(wrong)
        wait("the wrong code to be refused") { eventCount() >= 1 }
        guard case .rejected? = lastEvent() else { return XCTFail("expected rejected, got \(String(describing: lastEvent()))") }
        XCTAssertNil(trusted.device(for: androidDeviceId), "nothing is trusted after a wrong code")
        wait("the Android side to count the attempt", timeout: 15) { ((try? self.logLine(serial, prefix: "wrong attempts_left=")) ?? nil) == "4" }

        // ---- 2. The right code (typed in lower case, no dash) pairs both sides. ----
        transport.enterCode(plain.lowercased())
        wait("the pairing to succeed", timeout: 30) { eventCount() >= 2 }
        guard case .succeeded(let peer)? = lastEvent() else { return XCTFail("expected success, got \(String(describing: lastEvent()))") }
        XCTAssertEqual(peer.deviceId, androidDeviceId)
        let row = try XCTUnwrap(trusted.device(for: androidDeviceId), "the Android device is trusted")
        XCTAssertNotNil(row.signingPublicKeyBase64)
        wait("the Android side to trust the Mac", timeout: 15) { ((try? self.logLine(serial, prefix: "paired with ")) ?? nil) == identity.deviceId }

        // ---- 3. They now connect the normal way: both trust each other, so no prompt. ----
        let key = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: try XCTUnwrap(Data(base64Encoded: row.publicKeyBase64)))
        transport.connect(toFallbackHost: "127.0.0.1", port: try XCTUnwrap(NWEndpoint.Port(rawValue: forwardedPort)), remoteStaticKey: key, deviceId: androidDeviceId)
        wait("the Mac to connect to the Android device (connected: \(transport.connectedDeviceIds), state: \(transport.connectionState), android id \(androidDeviceId))", timeout: 30) { transport.connectedDeviceIds.contains(androidDeviceId) }
        print("MAC connected: \(transport.connectedDeviceIds) state \(transport.connectionState)")
        wait("the Android side to see the connection", timeout: 30) { ((try? self.logLine(serial, prefix: "connected to ")) ?? nil) == identity.deviceId }
    }
}
