import Foundation
import Security

/// Where a small secret blob (the identity keys, the trust roster) lives. Production uses the login Keychain
/// (`KeychainBlobStore`); tests inject a plain file (`FileBlobStore`).
protocol SecretBlobStore {
    func read() -> Data?
    @discardableResult func write(_ data: Data) -> Bool
}

/// A `0600` file written atomically via `PrivateFile`. Used by tests, and as the legacy location that
/// `KeychainBlobStore` migrates out of.
struct FileBlobStore: SecretBlobStore {
    let url: URL

    func read() -> Data? { try? Data(contentsOf: url) }
    func write(_ data: Data) -> Bool { PrivateFile.write(data, to: url) }
}

/// Stores the blob as a generic-password item in the login Keychain, so other processes of the same user can't read
/// it, or silently rewrite it, without macOS's access prompt. The item's ACL trusts the app that created it, so this
/// relies on a stable code-signing identity (`mac/scripts/create-signing-cert.sh`); an ad-hoc rebuild is treated as a
/// different app and prompts.
///
/// Migration: the first run after upgrading finds the old plaintext `legacyFile`, copies it into the Keychain,
/// reads it back to confirm, and only then overwrites and deletes the file. If the Keychain is unusable (locked,
/// access denied, headless CI) the store falls back to the legacy file rather than regenerating the device
/// identity or dropping every paired device, and logs that it did.
final class KeychainBlobStore: SecretBlobStore {
    private let service: String
    private let account: String
    private let legacy: FileBlobStore

    init(service: String = "dev.vmd1.gossip", account: String, legacyFile: URL) {
        self.service = service
        self.account = account
        self.legacy = FileBlobStore(url: legacyFile)
    }

    func read() -> Data? {
        switch copyItem() {
        case .success(let data):
            // A leftover plaintext copy (e.g. a failed delete after a previous migration) must not outlive the Keychain item.
            removeLegacyFile()
            return data
        case .notFound:
            guard let data = legacy.read() else { return nil }
            migrate(data)
            return data
        case .failure(let status):
            gossipError("Keychain read failed for \(account) (OSStatus \(status)); using the legacy file")
            return legacy.read()
        }
    }

    @discardableResult
    func write(_ data: Data) -> Bool {
        if store(data) {
            removeLegacyFile()
            return true
        }
        gossipError("Keychain write failed for \(account); falling back to the legacy file")
        return legacy.write(data)
    }

    // MARK: - Keychain primitives

    private enum ReadResult {
        case success(Data)
        case notFound
        case failure(OSStatus)
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func copyItem() -> ReadResult {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            if let data = result as? Data { return .success(data) }
            return .failure(errSecDecode)
        case errSecItemNotFound:
            return .notFound
        default:
            return .failure(status)
        }
    }

    private func store(_ data: Data) -> Bool {
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = baseQuery
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Moves `data` from the legacy file into the Keychain; the file is only destroyed after a verified read-back.
    private func migrate(_ data: Data) {
        guard store(data), case .success(let readBack) = copyItem(), readBack == data else {
            gossipError("Could not migrate \(account) into the Keychain; leaving the legacy file in place")
            return
        }
        removeLegacyFile()
    }

    /// Best-effort scrub (overwrite, then unlink). APFS is copy-on-write and may keep old blocks, so this narrows
    /// the exposure rather than guaranteeing erasure.
    private func removeLegacyFile() {
        let url = legacy.url
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int else { return }
        if size > 0, let handle = try? FileHandle(forWritingTo: url) {
            try? handle.write(contentsOf: Data(count: size))
            try? handle.synchronize()
            try? handle.close()
        }
        try? FileManager.default.removeItem(at: url)
    }
}
