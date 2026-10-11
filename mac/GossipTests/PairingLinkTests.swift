import XCTest
@testable import Gossip

final class PairingLinkTests: XCTestCase {
    private let json = #"{"responderDeviceName":"Café “Mac” 日本","pairingToken":"t","k":"a+b/c=="}"#

    func testRoundTripIncludingNonAscii() throws {
        let link = PairingLink.encode(json: Data(json.utf8))
        XCTAssertTrue(link.hasPrefix("gossip-pair:"))
        XCTAssertFalse(link.contains { "{}\"=+/ ".contains($0) }, "typeable: no quotes, braces, padding or base64 symbols")
        XCTAssertEqual(String(data: try XCTUnwrap(PairingLink.decode(link)), encoding: .utf8), json)
    }

    func testToleratesWhitespaceAddedByChatApps() throws {
        let link = PairingLink.encode(json: Data(json.utf8))
        let wrapped = "  " + stride(from: 0, to: link.count, by: 40).map { String(link.dropFirst($0).prefix(40)) }.joined(separator: "\n") + "\n"
        XCTAssertEqual(String(data: try XCTUnwrap(PairingLink.decode(wrapped)), encoding: .utf8), json)
    }

    func testAcceptsTheRawQrJsonAndRejectsJunk() {
        XCTAssertEqual(PairingLink.decode(json).flatMap { String(data: $0, encoding: .utf8) }, json)
        XCTAssertNil(PairingLink.decode(""))
        XCTAssertNil(PairingLink.decode("hello"))
        XCTAssertNil(PairingLink.decode("gossip-pair:!!!"))
    }

    /// The Kotlin codec must produce the same text for the same bytes (it is the same format on both platforms).
    func testMatchesTheAndroidCodecOnAKnownVector() {
        XCTAssertEqual(PairingLink.encode(json: Data([0xfb, 0xff, 0xfe, 0x01])), "gossip-pair:-__-AQ")
    }
}
