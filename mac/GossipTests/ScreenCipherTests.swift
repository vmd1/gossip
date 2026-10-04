import XCTest
@testable import Gossip

final class ScreenCipherTests: XCTestCase {
    private func data(hex: String) -> Data {
        Data(stride(from: 0, to: hex.count, by: 2).map { i in
            UInt8(hex[hex.index(hex.startIndex, offsetBy: i)..<hex.index(hex.startIndex, offsetBy: i + 2)], radix: 16)!
        })
    }

    func testSharedVectorsMatch() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("schema/screen-cipher-vectors.json")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let secret = data(hex: root["secretHex"] as! String)
        let sessionId = root["sessionId"] as! String
        for c in root["cases"] as! [[String: Any]] {
            let viewer = c["viewerSends"] as! Bool
            let counter = UInt64(c["counter"] as! Int)
            let plaintext = data(hex: c["plaintextHex"] as! String)
            let sealed = data(hex: c["sealedHex"] as! String)
            XCTAssertEqual(try ScreenCipher(secret: secret, sessionId: sessionId, viewer: viewer).seal(plaintext, counter: counter), sealed)
            // the opposite end opens it
            XCTAssertEqual(try ScreenCipher(secret: secret, sessionId: sessionId, viewer: !viewer).open(sealed), plaintext)
        }
    }

    func testRejectsReplayForgeryWrongSessionAndReflection() throws {
        let secret = Data(repeating: 9, count: 32)
        let viewer = ScreenCipher(secret: secret, sessionId: "s1", viewer: true)
        let device = ScreenCipher(secret: secret, sessionId: "s1", viewer: false)
        let m1 = try viewer.seal(Data("one".utf8))
        let m2 = try viewer.seal(Data("two".utf8))
        XCTAssertEqual(try device.open(m1), Data("one".utf8))
        XCTAssertThrowsError(try device.open(m1)) // replay
        XCTAssertEqual(try device.open(m2), Data("two".utf8))

        var forged = try viewer.seal(Data("three".utf8)); forged[forged.count - 1] ^= 1
        XCTAssertThrowsError(try device.open(forged))
        XCTAssertThrowsError(try ScreenCipher(secret: secret, sessionId: "other", viewer: false).open(try viewer.seal(Data("x".utf8))))
        // a viewer-sent message can't be reflected back to the viewer
        XCTAssertThrowsError(try ScreenCipher(secret: secret, sessionId: "s1", viewer: true).open(try viewer.seal(Data("y".utf8))))
    }
}
