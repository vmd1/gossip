import XCTest
import CryptoKit
@testable import Gossip

final class ControlProtocolTests: XCTestCase {
    private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    private func data(hex: String) -> Data {
        var out = Data(); var i = hex.startIndex
        while i < hex.endIndex { let j = hex.index(i, offsetBy: 2); out.append(UInt8(hex[i..<j], radix: 16)!); i = j }
        return out
    }

    func testEveryFrameRoundTrips() {
        let frames: [ControlFrame] = [
            .hello(sessionId: "abc"), .enter(edge: .bottom, position: 65535), .leave, .mouseMove(dx: -32768, dy: 32767),
            .buttons(0x1f), .scroll(dx: -1, dy: 1), .key(usage: 0xE7, down: false, modifiers: 0xff), .text("日本語 ✓"), .ping,
            .helloAck(ControlDisplayInfo(width: 2000, height: 1200, rotation: 3, backend: 1)),
            .displayInfo(ControlDisplayInfo(width: 1, height: 2, rotation: 0, backend: 0)), .error("nope"), .pong,
        ]
        for f in frames { XCTAssertEqual(ControlFrame.decode(f.encoded()), f, "\(f)") }
    }

    func testMalformedFramesAreRejected() {
        XCTAssertNil(ControlFrame.decode(Data()))
        XCTAssertNil(ControlFrame.decode(Data([0x99])))
        XCTAssertNil(ControlFrame.decode(Data([ControlFrame.Kind.enter, 9, 0, 0])))     // bad edge
        XCTAssertNil(ControlFrame.decode(Data([ControlFrame.Kind.mouseMove, 0, 1])))    // truncated
        XCTAssertNil(ControlFrame.decode(Data([ControlFrame.Kind.leave, 0])))           // trailing bytes
        XCTAssertNil(ControlFrame.decode(Data([ControlFrame.Kind.key, 0, 4, 2, 0])))    // bad down flag
    }

    func testSharedVectorsMatch() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("schema/control-test-vectors.json")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let secret = data(hex: root["secretHex"] as! String)
        let sessionId = root["sessionId"] as! String
        for c in root["cases"] as! [[String: Any]] {
            let name = c["name"] as! String
            let role: ControlDirection = (c["direction"] as! String) == "m2d" ? .macToDevice : .deviceToMac
            let counter = UInt64(c["counter"] as! Int)
            let plaintext = data(hex: c["plaintextHex"] as! String)
            let sealed = data(hex: c["sealedHex"] as! String)
            let sender = ControlCipher(secret: secret, sessionId: sessionId, role: role)
            XCTAssertEqual(hex(try sender.seal(plaintext: plaintext, counter: counter)), hex(sealed), name)
            var receiver = ControlCipher(secret: secret, sessionId: sessionId, role: role == .macToDevice ? .deviceToMac : .macToDevice)
            XCTAssertEqual(try receiver.open(sealed), ControlFrame.decode(plaintext), name)
        }
    }

    func testCipherRoundTripAndReplayProtection() throws {
        let secret = Data(repeating: 7, count: 32)
        var mac = ControlCipher(secret: secret, sessionId: "s", role: .macToDevice)
        var device = ControlCipher(secret: secret, sessionId: "s", role: .deviceToMac)
        let first = try mac.seal(.mouseMove(dx: 1, dy: 2))
        let second = try mac.seal(.mouseMove(dx: 3, dy: 4))
        XCTAssertEqual(try device.open(first), .mouseMove(dx: 1, dy: 2))
        XCTAssertEqual(try device.open(second), .mouseMove(dx: 3, dy: 4))
        // A duplicate (or older) frame is refused, so a re-delivery can't move the cursor twice.
        XCTAssertThrowsError(try device.open(first)) { XCTAssertEqual($0 as? ControlCipher.Failure, .replayed) }
        XCTAssertThrowsError(try device.open(second)) { XCTAssertEqual($0 as? ControlCipher.Failure, .replayed) }
        // And the device's own direction can't be fed back to it (reflection).
        XCTAssertThrowsError(try device.open(try device.seal(.pong)))
    }

    func testTamperingAndWrongKeysFail() throws {
        let secret = Data(repeating: 1, count: 32)
        var mac = ControlCipher(secret: secret, sessionId: "s", role: .macToDevice)
        var message = try mac.seal(.text("hi"))
        var device = ControlCipher(secret: secret, sessionId: "s", role: .deviceToMac)
        message[message.count - 1] ^= 1
        XCTAssertThrowsError(try device.open(message)) { XCTAssertEqual($0 as? ControlCipher.Failure, .authentication) }
        // A failed frame must not burn the counter: the genuine one still opens.
        var mac2 = ControlCipher(secret: secret, sessionId: "s", role: .macToDevice)
        XCTAssertEqual(try device.open(try mac2.seal(.ping)), .ping)
        var otherSession = ControlCipher(secret: secret, sessionId: "other", role: .deviceToMac)
        var mac3 = ControlCipher(secret: secret, sessionId: "s", role: .macToDevice)
        XCTAssertThrowsError(try otherSession.open(try mac3.seal(.ping)))
        var otherSecret = ControlCipher(secret: Data(repeating: 2, count: 32), sessionId: "s", role: .deviceToMac)
        var mac4 = ControlCipher(secret: secret, sessionId: "s", role: .macToDevice)
        XCTAssertThrowsError(try otherSecret.open(try mac4.seal(.ping)))
        XCTAssertThrowsError(try device.open(Data(count: 10))) // too short
    }

    func testCountersStrictlyIncrease() throws {
        var mac = ControlCipher(secret: Data(repeating: 3, count: 32), sessionId: "s", role: .macToDevice)
        _ = try mac.seal(.ping); _ = try mac.seal(.ping)
        XCTAssertEqual(mac.sendCounter, 2)
    }
}
