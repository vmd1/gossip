import Foundation
import CryptoKit

/// Generates (on first launch) and persists this Mac's stable device identity:
/// a UUID plus an Ed25519 signing keypair and an X25519 key-agreement keypair.
///
/// Stored as a JSON file in `~/Library/Application Support/Connect/identity.json`
/// (matching `TrustedDevicesStore`'s existing convention), not the macOS
/// Keychain. Keychain items are ACL'd to the requesting app's code-signing
/// identity, and this project is ad-hoc signed (`CODE_SIGN_STYLE: Automatic`,
/// no paid Developer ID yet) — ad-hoc signatures aren't stable across rebuilds,
/// so every rebuild during development made macOS treat Connect as a "new" app
/// and re-prompt for Keychain access on every launch. File-based storage in
/// Application Support (already the accepted tradeoff for `TrustedDevicesStore`
/// in this codebase) sidesteps that entirely. Revisit Keychain once the app is
/// signed with a stable Developer ID for distribution.
final class IdentityKeyStore {
    static let shared = IdentityKeyStore()

    private struct StoredIdentity: Codable {
        let deviceId: String
        let ed25519PrivateKey: Data
        let x25519PrivateKey: Data
    }

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.connect.app.identitykeystore")

    private var cached: StoredIdentity?
    private var cachedSigningKey: Curve25519.Signing.PrivateKey?
    private var cachedAgreementKey: Curve25519.KeyAgreement.PrivateKey?

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("Connect", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("identity.json")
        }
    }

    // MARK: - Public API

    /// This device's stable UUID, generated once and persisted forever.
    var deviceId: String {
        queue.sync { identity().deviceId }
    }

    /// The Ed25519 keypair used to sign identity assertions (e.g. during pairing confirmation).
    var signingKey: Curve25519.Signing.PrivateKey {
        queue.sync {
            if let cachedSigningKey { return cachedSigningKey }
            let key = (try? Curve25519.Signing.PrivateKey(rawRepresentation: identity().ed25519PrivateKey))
                ?? Curve25519.Signing.PrivateKey()
            cachedSigningKey = key
            return key
        }
    }

    /// The X25519 keypair used for Noise_IK key agreement.
    var agreementKey: Curve25519.KeyAgreement.PrivateKey {
        queue.sync {
            if let cachedAgreementKey { return cachedAgreementKey }
            let key = (try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: identity().x25519PrivateKey))
                ?? Curve25519.KeyAgreement.PrivateKey()
            cachedAgreementKey = key
            return key
        }
    }

    /// Base64 fingerprint (first 8 bytes of SHA256 of the raw public key) suitable
    /// for display and for the discovery TXT record.
    var publicKeyFingerprint: String {
        let hash = SHA256.hash(data: agreementKey.publicKey.rawRepresentation)
        return Data(hash.prefix(8)).base64EncodedString()
    }

    // MARK: - Persistence

    /// Loads the on-disk identity, generating and persisting a fresh one on
    /// first run (or if the file is missing/corrupt). Must be called on `queue`.
    private func identity() -> StoredIdentity {
        if let cached { return cached }
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(StoredIdentity.self, from: data) {
            cached = decoded
            return decoded
        }

        let fresh = StoredIdentity(
            deviceId: UUID().uuidString,
            ed25519PrivateKey: Curve25519.Signing.PrivateKey().rawRepresentation,
            x25519PrivateKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation
        )
        cached = fresh
        persist(fresh)
        return fresh
    }

    private func persist(_ identity: StoredIdentity) {
        guard let data = try? JSONEncoder().encode(identity) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
