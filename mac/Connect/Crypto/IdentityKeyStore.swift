import Foundation
import CryptoKit
import Security

/// Generates (on first launch) and persists this Mac's stable device identity:
/// a UUID plus an Ed25519 signing keypair and an X25519 key-agreement keypair.
/// Everything is stored in the macOS Keychain so it survives app relaunches
/// (and, unlike UserDefaults/a plist, isn't trivially copied off the machine).
final class IdentityKeyStore {
    static let shared = IdentityKeyStore()

    private let service = "com.connect.app.identity"
    private let deviceIdAccount = "deviceId"
    private let signingKeyAccount = "ed25519PrivateKey"
    private let agreementKeyAccount = "x25519PrivateKey"

    private let queue = DispatchQueue(label: "com.connect.app.identitykeystore")

    private var cachedDeviceId: String?
    private var cachedSigningKey: Curve25519.Signing.PrivateKey?
    private var cachedAgreementKey: Curve25519.KeyAgreement.PrivateKey?

    private init() {}

    // MARK: - Public API

    /// This device's stable UUID, generated once and persisted forever.
    var deviceId: String {
        queue.sync {
            if let cachedDeviceId { return cachedDeviceId }
            if let existing = readString(account: deviceIdAccount) {
                cachedDeviceId = existing
                return existing
            }
            let newId = UUID().uuidString
            _ = writeString(newId, account: deviceIdAccount)
            cachedDeviceId = newId
            return newId
        }
    }

    /// The Ed25519 keypair used to sign identity assertions (e.g. during pairing confirmation).
    var signingKey: Curve25519.Signing.PrivateKey {
        queue.sync {
            if let cachedSigningKey { return cachedSigningKey }
            if let data = readData(account: signingKeyAccount),
               let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
                cachedSigningKey = key
                return key
            }
            let newKey = Curve25519.Signing.PrivateKey()
            _ = writeData(newKey.rawRepresentation, account: signingKeyAccount)
            cachedSigningKey = newKey
            return newKey
        }
    }

    /// The X25519 keypair used for Noise_IK key agreement.
    var agreementKey: Curve25519.KeyAgreement.PrivateKey {
        queue.sync {
            if let cachedAgreementKey { return cachedAgreementKey }
            if let data = readData(account: agreementKeyAccount),
               let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) {
                cachedAgreementKey = key
                return key
            }
            let newKey = Curve25519.KeyAgreement.PrivateKey()
            _ = writeData(newKey.rawRepresentation, account: agreementKeyAccount)
            cachedAgreementKey = newKey
            return newKey
        }
    }

    /// Base64 fingerprint (first 8 bytes of SHA256 of the raw public key) suitable
    /// for display and for the discovery TXT record.
    var publicKeyFingerprint: String {
        let hash = SHA256.hash(data: agreementKey.publicKey.rawRepresentation)
        return Data(hash.prefix(8)).base64EncodedString()
    }

    // MARK: - Keychain primitives

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func readData(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    @discardableResult
    private func writeData(_ data: Data, account: String) -> Bool {
        // Try update first (item may already exist from a partial previous run).
        let query = baseQuery(account: account)
        let attributesToUpdate: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }

        var addQuery = baseQuery(account: account)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        return addStatus == errSecSuccess
    }

    private func readString(account: String) -> String? {
        guard let data = readData(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private func writeString(_ string: String, account: String) -> Bool {
        guard let data = string.data(using: .utf8) else { return false }
        return writeData(data, account: account)
    }
}
