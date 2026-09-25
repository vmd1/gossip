import Foundation
import CryptoKit
import CoreBluetooth

/// Wire-level contract for Instant Hotspot's BLE GATT control channel — see
/// `docs/ble-hotspot-protocol.md`. This travels over a raw GATT service, not the
/// Noise-encrypted Wi-Fi mesh transport (`schema/message-types.md`/`Envelope`), since the
/// whole point of Instant Hotspot is reaching a device with no IP connectivity at all,
/// which rules out the mesh transport by definition. Swift and Kotlin
/// (`HotspotGattProtocol.kt`) each implement this independently, same as every other
/// wire-level contract in this project — the two files are the source of truth both must
/// agree on byte-for-byte.
enum HotspotGattProtocol {
    /// Custom 128-bit UUIDs — this is a personal project, not requiring SIG
    /// registration, same rationale as the `0xFFFF` "for testing" manufacturer ID used
    /// for BLE proximity advertising (`docs/ble-proximity-protocol.md`). Must match
    /// `HotspotGattProtocol.kt`'s constants exactly.
    static let serviceUUID = CBUUID(string: "8f9a1000-1a2b-4c3d-9e0f-1234567890ab")
    static let requestCharacteristicUUID = CBUUID(string: "8f9a1001-1a2b-4c3d-9e0f-1234567890ab")
    static let responseCharacteristicUUID = CBUUID(string: "8f9a1002-1a2b-4c3d-9e0f-1234567890ab")

    /// Payload bytes per GATT write/notify chunk — see `HotspotGattProtocol.kt`'s
    /// matching constant for the full "never depends on MTU negotiation" rationale.
    static let chunkPayloadSize = 19
    private static let flagLastChunk: UInt8 = 0x01

    static func encodeChunks(_ message: Data) -> [Data] {
        if message.isEmpty { return [Data([flagLastChunk])] }
        var chunks: [Data] = []
        var offset = 0
        while offset < message.count {
            let end = min(offset + chunkPayloadSize, message.count)
            let isLast = end == message.count
            var chunk = Data([isLast ? flagLastChunk : 0])
            chunk.append(message.subdata(in: offset..<end))
            chunks.append(chunk)
            offset = end
        }
        return chunks
    }

    /// Reassembles chunks written/notified one at a time back into the original
    /// message. Not thread-safe by design — callers own serializing chunk delivery per
    /// connection, same as `HotspotGattProtocol.kt`'s `ChunkReassembler`.
    final class ChunkReassembler {
        private var buffer = Data()

        /// Feeds one chunk; returns the complete reassembled message once the last
        /// chunk arrives, or `nil` if more chunks are still expected. Resets
        /// automatically after returning a complete message.
        func feed(_ chunk: Data) -> Data? {
            guard !chunk.isEmpty else { return nil }
            buffer.append(chunk.dropFirst())
            guard (chunk[chunk.startIndex] & flagLastChunk) != 0 else { return nil }
            let result = buffer
            buffer = Data()
            return result
        }
    }

    struct ToggleRequestPayload: Codable {
        let id: String
        let en: Bool
        let n: String
        let s: String

        /// Builds and signs a fresh request. [signingKey] is the requester's Ed25519
        /// signing key (`IdentityKeyStore.signingKey`).
        static func create(requesterId: String, enable: Bool, signingKey: Curve25519.Signing.PrivateKey) -> ToggleRequestPayload {
            let nonce = UUID().uuidString
            let signature = sign(signingKey, signedString(requesterId, enable, nonce))
            return ToggleRequestPayload(id: requesterId, en: enable, n: nonce, s: signature)
        }

        func isSignatureValid(signingPublicKeyBase64: String) -> Bool {
            verify(signingPublicKeyBase64, Self.signedString(id, en, n), s)
        }

        private static func signedString(_ requesterId: String, _ enable: Bool, _ nonce: String) -> String {
            "hotspot.toggle_request|\(requesterId)|\(enable)|\(nonce)"
        }
    }

    private struct CredentialPlaintext: Codable {
        let ssid: String
        let pass: String
    }

    /// `cred`, when present, is base64(12-byte AES-GCM nonce || ciphertext+tag)
    /// encrypting a compact JSON `{"ssid":...,"pass":...}` — see
    /// `encryptCredentials`/`decryptCredentials`. Signed over the *ciphertext* (not
    /// plaintext credentials), so the signature also protects the ciphertext's
    /// integrity end to end, on top of AES-GCM's own built-in tag.
    struct StatusPayload: Codable {
        let id: String
        let ok: Bool
        let n: String
        let s: String
        let cred: String?

        func isSignatureValid(signingPublicKeyBase64: String) -> Bool {
            verify(signingPublicKeyBase64, Self.signedString(id, ok, cred, n), s)
        }

        /// Decrypts `cred` using the shared secret derived between this device and the
        /// provider (see `deriveSharedSecretKey`). Returns `nil` if there was no
        /// credential blob or decryption fails (wrong key, tampered ciphertext —
        /// AES-GCM's tag catches this). Callers must check `isSignatureValid`
        /// separately first — this method doesn't re-check it.
        func decryptCredentials(sharedSecretKey: SymmetricKey) -> (ssid: String, passphrase: String)? {
            guard let blob = cred else { return nil }
            return HotspotGattProtocol.decryptCredentials(sharedSecretKey, blob)
        }

        fileprivate static func signedString(_ providerId: String, _ enabled: Bool, _ cred: String?, _ nonce: String) -> String {
            "hotspot.status|\(providerId)|\(enabled)|\(cred ?? "")|\(nonce)"
        }
    }

    /// Derives a symmetric key from this device's X25519 identity private key and the
    /// peer's X25519 identity public key (the same static keys `TrustedDevice.
    /// publicKeyBase64` already stores and Noise_IK already uses) via ECDH, then
    /// SHA-256 with a domain-separation label — **not** the raw ECDH output — so this
    /// key can never collide with (or weaken) the Noise_IK session key the same keypair
    /// also derives. Must match `HotspotGattProtocol.kt`'s `deriveSharedSecretKey`
    /// byte-for-byte (same label, same construction) since either side of the
    /// conversation may compute it.
    static func deriveSharedSecretKey(localAgreementKey: Curve25519.KeyAgreement.PrivateKey, remotePublicKey: Curve25519.KeyAgreement.PublicKey) -> SymmetricKey {
        // X25519 agreement between two already-validated 32-byte keys doesn't fail in
        // practice (there's no additional curve-point validation X25519 requires beyond
        // the raw-length check `Curve25519.KeyAgreement.PublicKey(rawRepresentation:)`
        // already performed at construction) — `try!` documents that expectation rather
        // than threading an unreachable error path through every caller.
        let sharedSecret = try! localAgreementKey.sharedSecretFromKeyAgreement(with: remotePublicKey)
        var digest = SHA256()
        sharedSecret.withUnsafeBytes { digest.update(bufferPointer: $0) }
        digest.update(data: "connect-hotspot-gatt-v1".data(using: .utf8)!)
        return SymmetricKey(data: Data(digest.finalize()))
    }

    private static func encryptCredentials(_ key: SymmetricKey, _ ssid: String, _ passphrase: String) -> String? {
        guard let plaintext = try? JSONEncoder().encode(CredentialPlaintext(ssid: ssid, pass: passphrase)) else { return nil }
        guard let sealed = try? AES.GCM.seal(plaintext, using: key) else { return nil }
        guard let combined = sealed.combined else { return nil }
        return combined.base64EncodedString()
    }

    private static func decryptCredentials(_ key: SymmetricKey, _ blob: String) -> (ssid: String, passphrase: String)? {
        guard let raw = Data(base64Encoded: blob) else { return nil }
        guard let sealedBox = try? AES.GCM.SealedBox(combined: raw) else { return nil }
        guard let plaintext = try? AES.GCM.open(sealedBox, using: key) else { return nil }
        guard let decoded = try? JSONDecoder().decode(CredentialPlaintext.self, from: plaintext) else { return nil }
        return (decoded.ssid, decoded.pass)
    }

    private static func sign(_ signingKey: Curve25519.Signing.PrivateKey, _ message: String) -> String {
        let signature = (try? signingKey.signature(for: Data(message.utf8))) ?? Data()
        return signature.base64EncodedString()
    }

    private static func verify(_ publicKeyBase64: String, _ message: String, _ signatureBase64: String) -> Bool {
        guard let publicKeyData = Data(base64Encoded: publicKeyBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData),
              let signature = Data(base64Encoded: signatureBase64)
        else { return false }
        return publicKey.isValidSignature(signature, for: Data(message.utf8))
    }

    static func encodeRequest(_ payload: ToggleRequestPayload) -> Data {
        (try? JSONEncoder().encode(payload)) ?? Data()
    }

    static func decodeRequest(_ data: Data) -> ToggleRequestPayload? {
        try? JSONDecoder().decode(ToggleRequestPayload.self, from: data)
    }

    static func encodeStatus(_ payload: StatusPayload) -> Data {
        (try? JSONEncoder().encode(payload)) ?? Data()
    }

    static func decodeStatus(_ data: Data) -> StatusPayload? {
        try? JSONDecoder().decode(StatusPayload.self, from: data)
    }

    static func makeStatusPayload(
        providerId: String,
        enabled: Bool,
        nonce: String,
        signingKey: Curve25519.Signing.PrivateKey,
        sharedSecretKey: SymmetricKey? = nil,
        ssid: String? = nil,
        passphrase: String? = nil
    ) -> StatusPayload {
        var cred: String? = nil
        if let ssid, let passphrase, let sharedSecretKey {
            cred = encryptCredentials(sharedSecretKey, ssid, passphrase)
        }
        let signature = sign(signingKey, StatusPayload.signedString(providerId, enabled, cred, nonce))
        return StatusPayload(id: providerId, ok: enabled, n: nonce, s: signature, cred: cred)
    }
}
