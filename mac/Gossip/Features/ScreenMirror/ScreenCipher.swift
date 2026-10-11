import Foundation
import GossipCoreKit

/// Encrypts the screen-mirroring WebSocket (`ScreenBridge` on Android is the other end). The construction — HKDF-derived
/// directional ChaCha20-Poly1305 keys, an 8-byte strictly increasing counter nonce, AAD binding direction and session id —
/// is the core's `StreamCipher` (`desktop/core/src/crypto/stream.rs`), shared with every platform and checked against
/// `schema/screen-cipher-vectors.json` there. The per-session `secret` travels only in the Noise-encrypted `screen.ready`.
final class ScreenCipher {
    enum Failure: Error { case badLength, replayed, authentication }

    private let inner: GossipCoreKit.StreamCipher

    /// `viewer` is the Mac end (sends v2d, receives d2v).
    init(secret: Data, sessionId: String, viewer: Bool) {
        inner = GossipCoreKit.StreamCipher(profile: .screen, secret: secret, sessionId: sessionId, firstEnd: viewer)
    }

    func seal(_ plaintext: Data) throws -> Data { try inner.seal(plaintext: plaintext) }

    func open(_ message: Data) throws -> Data {
        do { return try inner.open(message: message) } catch { throw Self.failure(for: error) }
    }

    static func failure(for error: Error) -> Failure {
        let text = "\(error)"
        if text.contains("too short") { return .badLength }
        if text.contains("not greater") { return .replayed }
        return .authentication
    }
}
