import Foundation
import CryptoKit

/// Encrypts the screen-mirroring WebSocket (`ScreenBridge` on Android is the other end).
/// Same construction as `ControlCipher` (HKDF-derived directional ChaCha20-Poly1305 keys, an
/// 8-byte counter nonce that must strictly increase, AAD binding direction and session id)
/// under its own labels, applied to arbitrary payloads. The per-session `secret` travels only in
/// the Noise-encrypted `screen.ready` message. Checked against `schema/screen-cipher-vectors.json`.
final class ScreenCipher {
    enum Failure: Error { case badLength, replayed, authentication }

    private static let label = "gossip-screen-v1"
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private let sendDirection: UInt8
    private let receiveDirection: UInt8
    private let sessionIdData: Data
    private var sendCounter: UInt64 = 0
    private var lastReceived: UInt64 = 0
    private let lock = NSLock()

    /// `viewer` is the Mac end (sends v2d, receives d2v).
    init(secret: Data, sessionId: String, viewer: Bool) {
        sessionIdData = Data(sessionId.utf8)
        sendDirection = viewer ? 1 : 2
        receiveDirection = viewer ? 2 : 1
        func key(_ d: UInt8) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: Data(sessionId.utf8),
                                   info: Data("\(ScreenCipher.label) \(d == 1 ? "v2d" : "d2v")".utf8), outputByteCount: 32)
        }
        sendKey = key(sendDirection)
        receiveKey = key(receiveDirection)
    }

    private func aad(_ d: UInt8) -> Data {
        var a = Data(Self.label.utf8)
        a.append(d)
        a.append(sessionIdData)
        return a
    }

    private static func nonce(_ counter: UInt64) throws -> ChaChaPoly.Nonce {
        var n = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { n.append(contentsOf: $0) }
        return try ChaChaPoly.Nonce(data: n)
    }

    func seal(_ plaintext: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        sendCounter += 1
        return try seal(plaintext, counter: sendCounter)
    }

    /// Exposed for the shared test vectors (fixed counter).
    func seal(_ plaintext: Data, counter: UInt64) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: Self.nonce(counter), authenticating: aad(sendDirection))
        var out = Data()
        withUnsafeBytes(of: counter.bigEndian) { out.append(contentsOf: $0) }
        out.append(box.ciphertext)
        out.append(box.tag)
        return out
    }

    func open(_ message: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard message.count >= 8 + 16 else { throw Failure.badLength }
        let base = message.startIndex
        var counter: UInt64 = 0
        for i in 0..<8 { counter = (counter << 8) | UInt64(message[base + i]) }
        guard counter > lastReceived else { throw Failure.replayed }
        let plaintext: Data
        do {
            let box = try ChaChaPoly.SealedBox(nonce: Self.nonce(counter),
                                               ciphertext: message[(base + 8)..<(message.endIndex - 16)],
                                               tag: message[(message.endIndex - 16)...])
            plaintext = try ChaChaPoly.open(box, using: receiveKey, authenticating: aad(receiveDirection))
        } catch {
            throw Failure.authentication
        }
        lastReceived = counter // only after authentication, so garbage can't burn counters
        return plaintext
    }
}
