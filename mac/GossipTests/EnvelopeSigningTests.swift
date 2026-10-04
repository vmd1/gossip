import XCTest
import CryptoKit
@testable import Gossip

final class EnvelopeSigningTests: XCTestCase {
    private func vectors() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("schema/envelope-signing-vectors.json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    private func vectorEnvelope(_ root: [String: Any]) throws -> Envelope {
        try Envelope.decode(JSONSerialization.data(withJSONObject: root["envelope"]!))
    }

    func testCanonicalFormAndSignatureMatchTheSharedVector() throws {
        let root = try vectors()
        let envelope = try vectorEnvelope(root)
        XCTAssertEqual(String(decoding: try EnvelopeSigning.signingBytes(envelope), as: UTF8.self), root["canonical"] as? String)

        let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: root["signingPublicKey"] as! String)!)
        let signed = envelope.withSignature(root["signature"] as! String)
        XCTAssertTrue(EnvelopeSigning.verify(signed, publicKey: key))
    }

    func testTamperingBreaksTheSignatureButRelayingDoesNot() throws {
        let key = Curve25519.Signing.PrivateKey()
        let original = Envelope(type: "dnd.set", senderId: "11111111-1111-1111-1111-111111111111", recipientId: "22222222-2222-2222-2222-222222222222",
                                payload: .object(["enabled": .bool(true)]))
        let signed = try EnvelopeSigning.sign(original, with: key)
        XCTAssertTrue(EnvelopeSigning.verify(signed, publicKey: key.publicKey))

        // Each hop decrements ttl; the signature must survive that.
        XCTAssertTrue(EnvelopeSigning.verify(signed.withTTL(3), publicKey: key.publicKey))
        // And a wire round trip.
        XCTAssertTrue(EnvelopeSigning.verify(try Envelope.decode(try signed.encoded()), publicKey: key.publicKey))

        let forgedPayload = Envelope(id: signed.id, type: signed.type, senderId: signed.senderId, recipientId: signed.recipientId,
                                     ts: signed.ts, payload: .object(["enabled": .bool(false)], ), sig: signed.sig)
        XCTAssertFalse(EnvelopeSigning.verify(forgedPayload, publicKey: key.publicKey))
        let retargeted = Envelope(id: signed.id, type: signed.type, senderId: signed.senderId, recipientId: "33333333-3333-3333-3333-333333333333",
                                  ts: signed.ts, payload: signed.payload, sig: signed.sig)
        XCTAssertFalse(EnvelopeSigning.verify(retargeted, publicKey: key.publicKey))
        XCTAssertFalse(EnvelopeSigning.verify(signed, publicKey: Curve25519.Signing.PrivateKey().publicKey))
        XCTAssertFalse(EnvelopeSigning.verify(original, publicKey: key.publicKey)) // unsigned
    }

    func testFractionalNumbersCannotBeSigned() {
        let e = Envelope(type: "battery.update", senderId: "11111111-1111-1111-1111-111111111111", payload: .object(["level": .number(0.5)]))
        XCTAssertThrowsError(try EnvelopeSigning.sign(e, with: Curve25519.Signing.PrivateKey()))
    }
}
