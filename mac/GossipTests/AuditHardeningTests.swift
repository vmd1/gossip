import XCTest
import CryptoKit
@testable import Gossip

final class AuditHardeningTests: XCTestCase {
    func testRawFrameHashIsBoundIntoThePayloadAndChecked() {
        let raw = Data([1, 2, 3, 4])
        let env = Envelope(type: "clipboard.update", senderId: "s", hasRawFollowup: true)
        let bound = TransportManager.bindingRawFrame(raw, to: env)
        XCTAssertTrue(TransportManager.rawFrameMatches(raw, envelope: bound))
        XCTAssertFalse(TransportManager.rawFrameMatches(Data([1, 2, 3, 5]), envelope: bound))
        XCTAssertFalse(TransportManager.rawFrameMatches(raw, envelope: env))
    }

    func testEnvelopesWithHugeIdsOrStaleTimestampsAreRejected() {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        XCTAssertTrue(TransportManager.isWellFormed(Envelope(type: "a.b", senderId: UUID().uuidString), now: now))
        XCTAssertFalse(TransportManager.isWellFormed(Envelope(id: String(repeating: "x", count: 65), type: "a.b", senderId: "s"), now: now))
        XCTAssertFalse(TransportManager.isWellFormed(Envelope(type: "a.b", senderId: "s", ts: now - 16 * 60 * 1000), now: now))
        XCTAssertFalse(TransportManager.isWellFormed(Envelope(type: "a.b", senderId: "s", ts: now + 16 * 60 * 1000), now: now))
    }

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
