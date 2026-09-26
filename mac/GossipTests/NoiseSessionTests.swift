import XCTest
import CryptoKit
@testable import Gossip

final class NoiseSessionTests: XCTestCase {

    func testHandshakeRoundTripAndTransportEncryption() throws {
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderStatic = Curve25519.KeyAgreement.PrivateKey()

        let initiator = NoiseSession(
            role: .initiator,
            localStaticKey: initiatorStatic,
            remoteStaticKey: responderStatic.publicKey
        )
        let responder = NoiseSession(
            role: .responder,
            localStaticKey: responderStatic,
            remoteStaticKey: nil
        )

        let helloPayload = Data("hello-from-initiator".utf8)
        let message1 = try initiator.createMessage1(payload: helloPayload)
        XCTAssertEqual(initiator.state, .handshaking)

        let receivedHello = try responder.consumeMessage1(message1)
        XCTAssertEqual(receivedHello, helloPayload)
        XCTAssertEqual(responder.peerStaticKey?.rawRepresentation, initiatorStatic.publicKey.rawRepresentation)

        let ackPayload = Data("ack-from-responder".utf8)
        let message2 = try responder.createMessage2(payload: ackPayload)
        XCTAssertEqual(responder.state, .established)

        let receivedAck = try initiator.consumeMessage2(message2)
        XCTAssertEqual(receivedAck, ackPayload)
        XCTAssertEqual(initiator.state, .established)
        XCTAssertEqual(initiator.peerStaticKey?.rawRepresentation, responderStatic.publicKey.rawRepresentation)

        // Post-handshake transport encryption, both directions.
        let plaintextToResponder = Data("clipboard: hello world".utf8)
        let ciphertext1 = try initiator.encrypt(plaintextToResponder)
        let decrypted1 = try responder.decrypt(ciphertext1)
        XCTAssertEqual(decrypted1, plaintextToResponder)

        let plaintextToInitiator = Data("presence.heartbeat".utf8)
        let ciphertext2 = try responder.encrypt(plaintextToInitiator)
        let decrypted2 = try initiator.decrypt(ciphertext2)
        XCTAssertEqual(decrypted2, plaintextToInitiator)

        // Multiple messages in a row (nonce increments correctly).
        for i in 0..<5 {
            let msg = Data("message-\(i)".utf8)
            let ct = try initiator.encrypt(msg)
            let pt = try responder.decrypt(ct)
            XCTAssertEqual(pt, msg)
        }
    }

    func testTamperedCiphertextFailsToDecrypt() throws {
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderStatic = Curve25519.KeyAgreement.PrivateKey()

        let initiator = NoiseSession(role: .initiator, localStaticKey: initiatorStatic, remoteStaticKey: responderStatic.publicKey)
        let responder = NoiseSession(role: .responder, localStaticKey: responderStatic, remoteStaticKey: nil)

        let message1 = try initiator.createMessage1(payload: Data())
        _ = try responder.consumeMessage1(message1)
        let message2 = try responder.createMessage2(payload: Data())
        _ = try initiator.consumeMessage2(message2)

        var ciphertext = try initiator.encrypt(Data("secret".utf8))
        // NOTE: the `Data` returned here is not guaranteed to be zero-based
        // (concatenation can preserve an internal buffer's original offset),
        // so index via `startIndex` rather than assuming `[0]` is valid.
        ciphertext[ciphertext.startIndex] ^= 0xFF

        XCTAssertThrowsError(try responder.decrypt(ciphertext)) { error in
            XCTAssertTrue(error is NoiseError)
        }
    }

    func testWrongRemoteStaticKeyFailsHandshake() throws {
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderStatic = Curve25519.KeyAgreement.PrivateKey()
        let wrongKey = Curve25519.KeyAgreement.PrivateKey()

        // Initiator believes it's talking to `wrongKey`'s owner, but the
        // actual responder holds `responderStatic`.
        let initiator = NoiseSession(role: .initiator, localStaticKey: initiatorStatic, remoteStaticKey: wrongKey.publicKey)
        let responder = NoiseSession(role: .responder, localStaticKey: responderStatic, remoteStaticKey: nil)

        let message1 = try initiator.createMessage1(payload: Data())
        XCTAssertThrowsError(try responder.consumeMessage1(message1))
    }

    func testRekeyProducesDifferentCiphertextForSamePlaintext() throws {
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderStatic = Curve25519.KeyAgreement.PrivateKey()

        let initiator = NoiseSession(role: .initiator, localStaticKey: initiatorStatic, remoteStaticKey: responderStatic.publicKey)
        let responder = NoiseSession(role: .responder, localStaticKey: responderStatic, remoteStaticKey: nil)

        let message1 = try initiator.createMessage1(payload: Data())
        _ = try responder.consumeMessage1(message1)
        let message2 = try responder.createMessage2(payload: Data())
        _ = try initiator.consumeMessage2(message2)

        let plaintext = Data("same message".utf8)
        let before = try initiator.encrypt(plaintext)
        // Keep both sides' nonce counters in lockstep, exactly as a real
        // session would (every encrypt on one side is decrypted by the other).
        _ = try responder.decrypt(before)

        initiator.rekey()
        responder.rekey()

        let after = try initiator.encrypt(plaintext)
        XCTAssertNotEqual(before, after)
        let decrypted = try responder.decrypt(after)
        XCTAssertEqual(decrypted, plaintext)
    }
}
