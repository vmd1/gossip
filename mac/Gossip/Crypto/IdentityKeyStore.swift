import Foundation
import CryptoKit

/// Generates (on first launch) and persists this Mac's stable device identity:
/// a UUID plus an Ed25519 signing keypair and an X25519 key-agreement keypair.
///
/// Stored as JSON in the login Keychain (`KeychainBlobStore`), so another process of the same user can't read the
/// private keys from disk. A pre-Keychain `~/Library/Application Support/Connect/identity.json` is migrated into the
/// Keychain on first launch and then scrubbed. The Keychain ACL trusts the app's code-signing identity, which is
/// stable now that builds are signed with `gossip.vmd1.dev` (`mac/scripts/create-signing-cert.sh`).
final class IdentityKeyStore {
    static let shared = IdentityKeyStore()

    private struct StoredIdentity: Codable {
        let deviceId: String
        let ed25519PrivateKey: Data
        let x25519PrivateKey: Data
        /// Random key shared with trusted peers so they can recognise this device's BLE advertisements
        /// (see `BeaconTag`). Optional so an identity file from before it existed still decodes.
        var beaconKey: Data?
    }

    private let blob: SecretBlobStore
    private let queue = DispatchQueue(label: "dev.vmd1.gossip.identitykeystore")

    private var cached: StoredIdentity?
    private var cachedSigningKey: Curve25519.Signing.PrivateKey?
    private var cachedAgreementKey: Curve25519.KeyAgreement.PrivateKey?

    init(blob: SecretBlobStore) {
        self.blob = blob
    }

    /// File-backed store at `fileURL`; used by tests.
    convenience init(fileURL: URL) {
        self.init(blob: FileBlobStore(url: fileURL))
    }

    /// The production store: Keychain, migrating from the legacy file.
    convenience init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        // Deliberately still "Connect", not "Gossip" — this is the on-disk
        // ~/Library/Application Support directory that held IdentityKeyStore's
        // device identity and TrustedDevicesStore's pairing state. Renaming it
        // would orphan the legacy file we migrate from.
        let dir = appSupport.appendingPathComponent("Connect", isDirectory: true)
        PrivateFile.ensureDirectory(dir)
        self.init(blob: KeychainBlobStore(account: "identity", legacyFile: dir.appendingPathComponent("identity.json")))
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

    /// This device's BLE beacon key, generated and persisted on first use.
    var beaconKey: Data {
        queue.sync {
            var stored = identity()
            if let key = stored.beaconKey { return key }
            let key = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
            stored.beaconKey = key
            cached = stored
            persist(stored)
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

    /// Loads the stored identity, generating and persisting a fresh one on
    /// first run (or if the stored identity is missing/corrupt). Must be called on `queue`.
    private func identity() -> StoredIdentity {
        if let cached { return cached }
        if let data = blob.read(),
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
        blob.write(data)
    }
}
