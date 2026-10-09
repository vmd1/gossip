import Foundation
import CryptoKit

/// Errors surfaced by the Noise_IK handshake / transport implementation.
enum NoiseError: Error, LocalizedError {
    case missingRemoteStatic
    case invalidMessage
    case decryptionFailed
    case notEstablished
    case alreadyEstablished
    case wrongRole

    var errorDescription: String? {
        switch self {
        case .missingRemoteStatic: return "Noise_IK requires the remote static public key before the handshake starts."
        case .invalidMessage: return "Malformed Noise handshake message."
        case .decryptionFailed: return "Noise AEAD decryption failed (bad key, nonce, or tampered ciphertext)."
        case .notEstablished: return "Noise session has not completed its handshake yet."
        case .alreadyEstablished: return "Noise handshake has already completed; cannot process further handshake messages."
        case .wrongRole: return "This handshake method is not valid for this session's role."
        }
    }
}

enum NoiseRole {
    case initiator
    case responder
}

/// AEAD cipher state as defined by the Noise Protocol Framework (section 5.1).
/// Wraps a ChaChaPoly key + strictly increasing nonce.
struct NoiseCipherState {
    private(set) var key: SymmetricKey?
    private(set) var nonce: UInt64 = 0

    mutating func initializeKey(_ key: SymmetricKey?) {
        self.key = key
        self.nonce = 0
    }

    var hasKey: Bool { key != nil }

    /// Noise nonce encoding for ChaChaPoly: 4 zero bytes followed by the
    /// 8-byte little-endian counter (matches the reference implementations'
    /// use of libsodium's IETF ChaCha20-Poly1305 nonce layout).
    private static func nonceBytes(_ n: UInt64) -> Data {
        var data = Data(repeating: 0, count: 4)
        var little = n.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        return data
    }

    mutating func encryptWithAd(_ ad: Data, _ plaintext: Data) throws -> Data {
        guard let key else { return plaintext }
        let sealed = try ChaChaPoly.seal(
            plaintext,
            using: key,
            nonce: try ChaChaPoly.Nonce(data: Self.nonceBytes(nonce)),
            authenticating: ad
        )
        nonce += 1
        return sealed.ciphertext + sealed.tag
    }

    mutating func decryptWithAd(_ ad: Data, _ ciphertext: Data) throws -> Data {
        guard let key else { return ciphertext }
        let tagLength = 16
        guard ciphertext.count >= tagLength else { throw NoiseError.invalidMessage }
        let ct = ciphertext.prefix(ciphertext.count - tagLength)
        let tag = ciphertext.suffix(tagLength)
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: try ChaChaPoly.Nonce(data: Self.nonceBytes(nonce)),
                ciphertext: ct,
                tag: tag
            )
            let plaintext = try ChaChaPoly.open(box, using: key, authenticating: ad)
            nonce += 1
            return plaintext
        } catch {
            throw NoiseError.decryptionFailed
        }
    }

    /// Per Noise spec section 4.2: replace the key without resetting the nonce
    /// sequence's security properties, used to periodically rekey a long-lived
    /// transport session.
    mutating func rekey() {
        guard let key else { return }
        let maxNonce = Self.nonceBytes(UInt64.max)
        guard let sealed = try? ChaChaPoly.seal(
            Data(repeating: 0, count: 32),
            using: key,
            nonce: try! ChaChaPoly.Nonce(data: maxNonce),
            authenticating: Data()
        ) else { return }
        self.key = SymmetricKey(data: sealed.ciphertext.prefix(32))
    }
}

/// Symmetric state as defined by the Noise Protocol Framework (section 5.2):
/// tracks the running chaining key + transcript hash across the handshake.
struct NoiseSymmetricState {
    private(set) var chainingKey: SymmetricKey
    private(set) var h: Data
    var cipherState = NoiseCipherState()

    init(protocolName: String) {
        let nameData = Data(protocolName.utf8)
        if nameData.count <= 32 {
            h = nameData + Data(repeating: 0, count: 32 - nameData.count)
        } else {
            h = Data(SHA256.hash(data: nameData))
        }
        chainingKey = SymmetricKey(data: h)
    }

    private static func hmac(key: SymmetricKey, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }

    /// Noise HKDF (section 4.3), producing exactly two outputs.
    private static func hkdf2(chainingKey: SymmetricKey, ikm: Data) -> (Data, Data) {
        let tempKey = SymmetricKey(data: hmac(key: chainingKey, data: ikm))
        let output1 = hmac(key: tempKey, data: Data([0x01]))
        let output2 = hmac(key: tempKey, data: output1 + Data([0x02]))
        return (output1, output2)
    }

    mutating func mixKey(_ inputKeyMaterial: Data) {
        let (newCk, tempK) = Self.hkdf2(chainingKey: chainingKey, ikm: inputKeyMaterial)
        chainingKey = SymmetricKey(data: newCk)
        cipherState.initializeKey(SymmetricKey(data: tempK))
    }

    mutating func mixHash(_ data: Data) {
        h = Data(SHA256.hash(data: h + data))
    }

    @discardableResult
    mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
        let ciphertext = try cipherState.encryptWithAd(h, plaintext)
        mixHash(ciphertext)
        return ciphertext
    }

    mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
        let plaintext = try cipherState.decryptWithAd(h, ciphertext)
        mixHash(ciphertext)
        return plaintext
    }

    /// Splits the final chaining key into two independent transport cipher
    /// states, one per direction.
    mutating func split() -> (NoiseCipherState, NoiseCipherState) {
        let (out1, out2) = Self.hkdf2(chainingKey: chainingKey, ikm: Data())
        var c1 = NoiseCipherState(); c1.initializeKey(SymmetricKey(data: out1))
        var c2 = NoiseCipherState(); c2.initializeKey(SymmetricKey(data: out2))
        return (c1, c2)
    }
}

/// Implements the Noise_IK handshake pattern:
/// ```
/// <- s
/// ...
/// -> e, es, s, ss
/// <- e, ee, se
/// ```
/// The responder's static public key (`rs`) is known to the initiator
/// out-of-band (carried in the pairing QR code), which is what makes IK safe
/// to use on the very first connection as well as on reconnects.
final class NoiseSession {
    enum State: Equatable {
        case uninitialized
        case handshaking
        case established
        case failed(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.uninitialized, .uninitialized), (.handshaking, .handshaking), (.established, .established):
                return true
            case (.failed(let a), .failed(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    private static let protocolName = "Noise_IK_25519_ChaChaPoly_SHA256"

    private(set) var state: State = .uninitialized
    private let role: NoiseRole

    private var symmetricState: NoiseSymmetricState
    private let localStatic: Curve25519.KeyAgreement.PrivateKey
    private var localEphemeral: Curve25519.KeyAgreement.PrivateKey?
    private var remoteStatic: Curve25519.KeyAgreement.PublicKey?
    private var remoteEphemeral: Curve25519.KeyAgreement.PublicKey?

    /// Set once the handshake completes: cipher for messages this device sends.
    private var sendCipher: NoiseCipherState?
    /// Set once the handshake completes: cipher for messages this device receives.
    private var receiveCipher: NoiseCipherState?

    /// - Parameters:
    ///   - role: whether this device initiates (the one scanning/dialing out) or responds (accepting the connection).
    ///   - localStaticKey: this device's long-term X25519 identity key.
    ///   - remoteStaticKey: the peer's long-term X25519 public key. Required for the initiator (learned from the
    ///     pairing QR code or the `TrustedDevices` table); may be nil for the responder, who learns it from message 1.
    ///   - prologue: optional out-of-band data both sides commit to (unused here, but part of the Noise spec surface).
    init(role: NoiseRole, localStaticKey: Curve25519.KeyAgreement.PrivateKey, remoteStaticKey: Curve25519.KeyAgreement.PublicKey?, prologue: Data = Data()) {
        self.role = role
        self.localStatic = localStaticKey
        self.remoteStatic = remoteStaticKey
        self.symmetricState = NoiseSymmetricState(protocolName: Self.protocolName)
        self.symmetricState.mixHash(prologue)

        // Pre-message: "<- s" — both sides mix in the responder's static public key,
        // which the initiator already knows out-of-band.
        if role == .initiator, let remoteStaticKey {
            self.symmetricState.mixHash(remoteStaticKey.rawRepresentation)
        } else if role == .responder {
            self.symmetricState.mixHash(localStaticKey.publicKey.rawRepresentation)
        }
    }

    // MARK: - Initiator: message 1 (-> e, es, s, ss)

    /// Builds handshake message 1. `payload` (e.g. a JSON-encoded `handshake.hello`
    /// device-info blob) is encrypted under the key derived from `es`.
    /// `ephemeral` exists so the shared conformance vectors (`schema/noise-ik-vectors.json`) can fix the ephemeral key;
    /// production callers leave it `nil` and get a fresh random one.
    func createMessage1(payload: Data, ephemeral: Curve25519.KeyAgreement.PrivateKey? = nil) throws -> Data {
        guard role == .initiator else { throw NoiseError.wrongRole }
        guard state == .uninitialized else { throw NoiseError.alreadyEstablished }
        guard let rs = remoteStatic else { throw NoiseError.missingRemoteStatic }
        state = .handshaking

        let e = ephemeral ?? Curve25519.KeyAgreement.PrivateKey()
        localEphemeral = e

        var buffer = Data()
        buffer.append(e.publicKey.rawRepresentation)
        symmetricState.mixHash(e.publicKey.rawRepresentation)

        let es = try e.sharedSecretFromKeyAgreement(with: rs)
        symmetricState.mixKey(es.withUnsafeBytes { Data($0) })

        let encryptedStatic = try symmetricState.encryptAndHash(localStatic.publicKey.rawRepresentation)
        buffer.append(encryptedStatic)

        let ss = try localStatic.sharedSecretFromKeyAgreement(with: rs)
        symmetricState.mixKey(ss.withUnsafeBytes { Data($0) })

        let encryptedPayload = try symmetricState.encryptAndHash(payload)
        buffer.append(encryptedPayload)

        return buffer
    }

    // MARK: - Responder: consume message 1, produce message 2 (<- e, ee, se)

    /// Consumes handshake message 1 and returns the decrypted payload
    /// (e.g. the initiator's `handshake.hello` device info). Learns the
    /// initiator's static public key in the process.
    func consumeMessage1(_ data: Data) throws -> Data {
        guard role == .responder else { throw NoiseError.wrongRole }
        guard state == .uninitialized else { throw NoiseError.alreadyEstablished }
        state = .handshaking

        let ephemeralLen = 32
        guard data.count > ephemeralLen else { throw NoiseError.invalidMessage }
        let reBytes = data.subdata(in: data.startIndex..<(data.startIndex + ephemeralLen))
        let re = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: reBytes)
        remoteEphemeral = re
        symmetricState.mixHash(reBytes)

        let es = try localStatic.sharedSecretFromKeyAgreement(with: re)
        symmetricState.mixKey(es.withUnsafeBytes { Data($0) })

        // NOTE: `Data` slices (`.prefix`/`.suffix`) preserve the ORIGINAL
        // buffer's absolute indices rather than rebasing to 0, so further
        // relative offsets must be computed from `data`'s own indices (via
        // `subdata(in:)`) rather than chained off an already-sliced value.
        let encryptedStaticLen = 32 + 16
        let staticStart = data.startIndex + ephemeralLen
        let staticEnd = staticStart + encryptedStaticLen
        guard data.count >= ephemeralLen + encryptedStaticLen else { throw NoiseError.invalidMessage }
        let encryptedStatic = data.subdata(in: staticStart..<staticEnd)
        let decryptedStatic = try symmetricState.decryptAndHash(encryptedStatic)
        let rsRemote = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: decryptedStatic)
        remoteStatic = rsRemote

        let ss = try localStatic.sharedSecretFromKeyAgreement(with: rsRemote)
        symmetricState.mixKey(ss.withUnsafeBytes { Data($0) })

        let encryptedPayload = data.subdata(in: staticEnd..<data.endIndex)
        return try symmetricState.decryptAndHash(encryptedPayload)
    }

    /// Builds handshake message 2 and completes the handshake for the responder,
    /// splitting into transport cipher states.
    func createMessage2(payload: Data, ephemeral: Curve25519.KeyAgreement.PrivateKey? = nil) throws -> Data {
        guard role == .responder else { throw NoiseError.wrongRole }
        guard state == .handshaking else { throw NoiseError.notEstablished }
        guard let re = remoteEphemeral else { throw NoiseError.invalidMessage }

        let e = ephemeral ?? Curve25519.KeyAgreement.PrivateKey()
        localEphemeral = e

        var buffer = Data()
        buffer.append(e.publicKey.rawRepresentation)
        symmetricState.mixHash(e.publicKey.rawRepresentation)

        let ee = try e.sharedSecretFromKeyAgreement(with: re)
        symmetricState.mixKey(ee.withUnsafeBytes { Data($0) })

        guard let rsRemote = remoteStatic else { throw NoiseError.invalidMessage }
        let se = try e.sharedSecretFromKeyAgreement(with: rsRemote)
        symmetricState.mixKey(se.withUnsafeBytes { Data($0) })

        let encryptedPayload = try symmetricState.encryptAndHash(payload)
        buffer.append(encryptedPayload)

        // Responder finished sending its half; split now. c1 = initiator->responder,
        // c2 = responder->initiator per Noise section 5.3.
        let (c1, c2) = symmetricState.split()
        receiveCipher = c1
        sendCipher = c2
        state = .established

        return buffer
    }

    // MARK: - Initiator: consume message 2

    /// Consumes handshake message 2 and completes the handshake for the initiator.
    func consumeMessage2(_ data: Data) throws -> Data {
        guard role == .initiator else { throw NoiseError.wrongRole }
        guard state == .handshaking else { throw NoiseError.notEstablished }
        guard let e = localEphemeral else { throw NoiseError.invalidMessage }

        let ephemeralLen = 32
        guard data.count > ephemeralLen else { throw NoiseError.invalidMessage }
        let reBytes = data.subdata(in: data.startIndex..<(data.startIndex + ephemeralLen))
        let re = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: reBytes)
        remoteEphemeral = re
        symmetricState.mixHash(reBytes)

        let ee = try e.sharedSecretFromKeyAgreement(with: re)
        symmetricState.mixKey(ee.withUnsafeBytes { Data($0) })

        let se = try localStatic.sharedSecretFromKeyAgreement(with: re)
        symmetricState.mixKey(se.withUnsafeBytes { Data($0) })

        let encryptedPayload = data.subdata(in: (data.startIndex + ephemeralLen)..<data.endIndex)
        let payload = try symmetricState.decryptAndHash(encryptedPayload)

        let (c1, c2) = symmetricState.split()
        sendCipher = c1
        receiveCipher = c2
        state = .established

        return payload
    }

    // MARK: - Post-handshake transport encryption

    func encrypt(_ plaintext: Data) throws -> Data {
        guard state == .established else { throw NoiseError.notEstablished }
        return try sendCipher!.encryptWithAd(Data(), plaintext)
    }

    func decrypt(_ ciphertext: Data) throws -> Data {
        guard state == .established else { throw NoiseError.notEstablished }
        return try receiveCipher!.decryptWithAd(Data(), ciphertext)
    }

    /// Periodic rekey of both transport directions, per Noise spec section 4.2.
    func rekey() {
        sendCipher?.rekey()
        receiveCipher?.rekey()
    }

    /// The peer's static public key, known once the handshake completes (or,
    /// for the initiator, from the start).
    var peerStaticKey: Curve25519.KeyAgreement.PublicKey? { remoteStatic }
}
