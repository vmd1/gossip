import XCTest
@testable import Gossip

final class ScreenCipherTests: XCTestCase {
    private func data(hex: String) -> Data {
        Data(stride(from: 0, to: hex.count, by: 2).map { i in
            UInt8(hex[hex.index(hex.startIndex, offsetBy: i)..<hex.index(hex.startIndex, offsetBy: i + 2)], radix: 16)!
        })
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
