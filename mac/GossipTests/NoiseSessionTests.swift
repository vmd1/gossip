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

    /// The shared conformance vectors (`schema/noise-ik-vectors.json`), generated by an implementation independent of
    /// both apps. The Kotlin twin is `NoiseSessionTest`; the Rust core checks the same file.
    func testSharedNoiseVectors() throws {
        func data(_ hex: String) -> Data {
            Data(stride(from: 0, to: hex.count, by: 2).map { i in
                UInt8(hex[hex.index(hex.startIndex, offsetBy: i)..<hex.index(hex.startIndex, offsetBy: i + 2)], radix: 16)!
            })
        }
        func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("schema/noise-ik-vectors.json")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        for c in root["cases"] as! [[String: Any]] {
            let name = c["name"] as! String
            let iStatic = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data(c["initiatorStaticSecretHex"] as! String))
            let rStatic = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data(c["responderStaticSecretHex"] as! String))
            let iEph = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data(c["initiatorEphemeralSecretHex"] as! String))
            let rEph = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data(c["responderEphemeralSecretHex"] as! String))
            let initiator = NoiseSession(role: .initiator, localStaticKey: iStatic, remoteStaticKey: rStatic.publicKey)
            let responder = NoiseSession(role: .responder, localStaticKey: rStatic, remoteStaticKey: nil)

            let message1 = try initiator.createMessage1(payload: data(c["message1PayloadHex"] as! String), ephemeral: iEph)
            XCTAssertEqual(hex(message1), c["message1Hex"] as? String, "\(name): message 1")
            XCTAssertEqual(try responder.consumeMessage1(message1), data(c["message1PayloadHex"] as! String), name)
            let message2 = try responder.createMessage2(payload: data(c["message2PayloadHex"] as! String), ephemeral: rEph)
            XCTAssertEqual(hex(message2), c["message2Hex"] as? String, "\(name): message 2")
            XCTAssertEqual(try initiator.consumeMessage2(message2), data(c["message2PayloadHex"] as! String), name)

            for (n, step) in (c["transport"] as! [[String: Any]]).enumerated() {
                let (sender, receiver) = (step["direction"] as! String) == "i2r" ? (initiator, responder) : (responder, initiator)
                let plaintext = data(step["plaintextHex"] as! String)
                let ciphertext = try sender.encrypt(plaintext)
                XCTAssertEqual(hex(ciphertext), step["ciphertextHex"] as? String, "\(name): transport message \(n)")
                XCTAssertEqual(try receiver.decrypt(ciphertext), plaintext, "\(name): transport message \(n)")
            }
        }
    }
}
