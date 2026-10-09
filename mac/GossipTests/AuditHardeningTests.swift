import XCTest
import CryptoKit
@testable import Gossip

final class AuditHardeningTests: XCTestCase {
    // Envelope shape checks, raw-frame hash binding, replay windows and the other wire-level hardening moved into the
    // Rust engine along with the code (see desktop/core/tests/engine.rs); the cases below are what stays in the app.

    func testFingerprintAcceptsBothAdvertisementFormats() {
        let key = Data((0..<32).map { UInt8($0) })
        let digest = Data(SHA256.hash(data: key))
        XCTAssertTrue(TransportManager.fingerprintMatches(Data(digest.prefix(8)).base64EncodedString(), keyData: key))
        XCTAssertTrue(TransportManager.fingerprintMatches(String(digest.base64EncodedString().replacingOccurrences(of: "=", with: "").prefix(16)), keyData: key))
        XCTAssertFalse(TransportManager.fingerprintMatches("AAAAAAAAAAAA", keyData: key))
    }

    func testPairingCodeEntryNeedsTheExactSixDigits() {
        let code = PairingCode.make(Data(repeating: 1, count: 32), Data(repeating: 2, count: 32))
        XCTAssertTrue(PairingCode.entryMatches(code, expected: code))
        XCTAssertTrue(PairingCode.entryMatches(code.replacingOccurrences(of: " ", with: ""), expected: code))
        XCTAssertFalse(PairingCode.entryMatches("", expected: code))
        XCTAssertFalse(PairingCode.entryMatches(code + "1", expected: code))
    }

    func testRosterKeyValidation() {
        XCTAssertTrue(RosterGossipManager.isValidKey(Data(repeating: 0, count: 32).base64EncodedString()))
        XCTAssertFalse(RosterGossipManager.isValidKey(Data(repeating: 0, count: 31).base64EncodedString()))
        XCTAssertFalse(RosterGossipManager.isValidKey("***"))
    }

    func testNotificationIconMustBeASmallRealImage() {
        XCTAssertFalse(NotificationMirrorManager.isReasonableIcon(Data("not an image".utf8)))
        XCTAssertFalse(NotificationMirrorManager.isReasonableIcon(Data(count: NotificationMirrorManager.maxIconBytes + 1)))
    }
}
