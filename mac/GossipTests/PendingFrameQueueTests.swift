import XCTest
import CryptoKit
@testable import Gossip

/// Frames the initiator sends right after `handshake.ack` arrive while the responder is
/// still waiting for the user to confirm trust. They must survive that window: Noise
/// nonces are implicit counters, so a frame dropped undecrypted desyncs the session.
final class PendingFrameQueueTests: XCTestCase {

    private func establishedPair() throws -> (initiator: NoiseSession, responder: NoiseSession) {
        let iKey = Curve25519.KeyAgreement.PrivateKey()
        let rKey = Curve25519.KeyAgreement.PrivateKey()
        let initiator = NoiseSession(role: .initiator, localStaticKey: iKey, remoteStaticKey: rKey.publicKey)
        let responder = NoiseSession(role: .responder, localStaticKey: rKey, remoteStaticKey: nil)
        _ = try responder.consumeMessage1(try initiator.createMessage1(payload: Data()))
        _ = try initiator.consumeMessage2(try responder.createMessage2(payload: Data()))
        return (initiator, responder)
    }

    func testDroppingFramesBeforeConfirmationDesyncsTheSession() throws {
        let (initiator, responder) = try establishedPair()
        _ = try initiator.encrypt(Data("trust.roster_update".utf8)) // dropped undecrypted
        let later = try initiator.encrypt(Data("presence.heartbeat".utf8))
        XCTAssertThrowsError(try responder.decrypt(later))
    }

    func testQueuedFramesReplayInOrderAfterConfirmation() throws {
        let (initiator, responder) = try establishedPair()
        var queue = PendingFrameQueue()
        let messages = ["trust.roster_update", "battery.update", "dnd.update"]
        for m in messages { XCTAssertTrue(queue.enqueue(try initiator.encrypt(Data(m.utf8)))) }

        let replayed = try queue.drain().map { String(decoding: try responder.decrypt($0), as: UTF8.self) }
        XCTAssertEqual(replayed, messages)

        // The session is still in sync for frames arriving after promotion.
        let after = try initiator.encrypt(Data("post".utf8))
        XCTAssertEqual(try responder.decrypt(after), Data("post".utf8))
        XCTAssertTrue(queue.drain().isEmpty)
    }

    func testQueueIsBounded() {
        var queue = PendingFrameQueue()
        for _ in 0..<PendingFrameQueue.limit { XCTAssertTrue(queue.enqueue(Data([1]))) }
        XCTAssertFalse(queue.enqueue(Data([1])))
    }

    func testQueueIsBoundedByTotalBytes() {
        var queue = PendingFrameQueue()
        XCTAssertTrue(queue.enqueue(Data(count: PendingFrameQueue.byteLimit)))
        XCTAssertFalse(queue.enqueue(Data([1])))
        _ = queue.drain()
        XCTAssertTrue(queue.enqueue(Data([1])))
    }

    func testKeysMatchOnlyForTheStoredKey() {
        let a = Curve25519.KeyAgreement.PrivateKey().publicKey
        let b = Curve25519.KeyAgreement.PrivateKey().publicKey
        XCTAssertTrue(TransportManager.keysMatch(a.rawRepresentation.base64EncodedString(), a))
        XCTAssertFalse(TransportManager.keysMatch(a.rawRepresentation.base64EncodedString(), b))
        XCTAssertFalse(TransportManager.keysMatch("not base64!", a))
    }
}
