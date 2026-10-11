import Foundation
import Security

/// Where a small secret blob (the identity keys, the trust roster) lives. Production uses the login Keychain
/// (`KeychainBlobStore`); tests inject a plain file (`FileBlobStore`).
protocol SecretBlobStore {
    func read() -> Data?
    @discardableResult func write(_ data: Data) -> Bool
}

/// Picks the production blob store for `account`: the login Keychain in the real app, but a throwaway file when the
/// app is only the host of a unit-test run. The Keychain is the wrong place for tests twice over: a test host built
/// moments ago has a new code hash, which macOS treats as a different app and answers with an access prompt that a
/// headless run never sees (the host then hangs at launch), and the test host would otherwise read, and could write, the
/// real device identity and paired devices of whoever is running the tests, and advertise as their Mac.
enum ProductionBlobStore {
    static var isRunningUnderTest: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
    }

    static func make(account: String) -> SecretBlobStore {
        guard isRunningUnderTest else { return KeychainBlobStore(account: account) }
        return FileBlobStore(url: scratchDirectory.appendingPathComponent("\(account).json"))
    }

    /// Per test process, so parallel runs do not share state; the system cleans the temporary directory.
    private static let scratchDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gossip-test-stores-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        PrivateFile.ensureDirectory(dir)
        return dir
    }()
}

/// A `0600` file written atomically via `PrivateFile`. Tests only: the app itself keeps these secrets in the Keychain.
struct FileBlobStore: SecretBlobStore {
    let url: URL

    func read() -> Data? { try? Data(contentsOf: url) }
    func write(_ data: Data) -> Bool { PrivateFile.write(data, to: url) }
}

/// Stores the blob as a generic-password item in the login Keychain, so other processes of the same user can't read
/// it, or silently rewrite it, without macOS's access prompt.
///
/// An item added the plain way gets a *partition list* naming the code hash (`cdhash:...`) of the build that created it
/// (an app with no developer team ID has nothing stabler), and every rebuilt binary is then asked for the login password
/// again, signed or not. So items are created with an explicit access list that trusts this app by its path and code
/// signature requirement instead, which keeps other processes out and survives rebuilds signed with the same
/// certificate. An item that still has the old kind of access list is recreated that way once (see `upgradeAccessIfNeeded`).
///
/// The Keychain is the only place the secret lives: there is no file fallback. If the Keychain refuses a read of an item
/// that exists (the user denied the prompt, the Keychain is locked), `read()` returns nil and writes are refused until
/// the next launch, so a fresh value built because nothing could be read never replaces the real one.
final class KeychainBlobStore: SecretBlobStore {
    private let service: String
    private let account: String
    private let lock = NSLock()
    private var unreadableItemExists = false
    private let defaults: UserDefaults

    init(service: String = "dev.vmd1.gossip", account: String, defaults: UserDefaults = .standard) {
        self.service = service
        self.account = account
        self.defaults = defaults
    }

    private var upgradedKey: String { "keychain.accessUpgraded.\(service).\(account)" }

    func read() -> Data? {
        lock.lock(); defer { lock.unlock() }
        switch copyItem() {
        case .success(let data):
            unreadableItemExists = false
            upgradeAccessIfNeeded(data)
            return data
        case .notFound:
            unreadableItemExists = false
            return nil
        case .failure(let status):
            gossipError("Keychain read failed for \(account) (OSStatus \(status))")
            unreadableItemExists = true
            return nil
        }
    }

    @discardableResult
    func write(_ data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if unreadableItemExists {
            gossipError("Not writing \(account): its Keychain item could not be read, and writing would replace it")
            return false
        }
        if store(data) { return true }
        gossipError("Keychain write failed for \(account)")
        return false
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
        return add(data, withOwnAccess: true) || add(data, withOwnAccess: false)
    }

    private func add(_ data: Data, withOwnAccess: Bool) -> Bool {
        var add = baseQuery
        add[kSecValueData as String] = data
        if withOwnAccess {
            guard let access = Self.ownAccess(label: "\(service) \(account)") else { return false }
            add[kSecAttrAccess as String] = access
        }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// An access list that trusts only this app (by path and code signature requirement), so rebuilds signed with the
    /// same certificate keep access without a prompt and other processes still get one.
    private static func ownAccess(label: String) -> SecAccess? {
        var me: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(nil, &me) == errSecSuccess, let me else { return nil }
        var access: SecAccess?
        guard SecAccessCreate(label as CFString, [me] as CFArray, &access) == errSecSuccess else { return nil }
        return access
    }

    /// Items created before this change carry a partition list tied to one build's code hash. Recreates the item once,
    /// with the data already in hand and only after the new copy reads back, so a failure keeps the old item.
    private func upgradeAccessIfNeeded(_ data: Data) {
        guard !defaults.bool(forKey: upgradedKey) else { return }
        defer { defaults.set(true, forKey: upgradedKey) }
        guard let access = Self.ownAccess(label: "\(service) \(account)") else { return }
        var query = baseQuery
        query[kSecReturnRef as String] = true
        var ref: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &ref) == errSecSuccess, let ref else { return }
        // SecKeychainItemSetAccess replaces the access list in place, so nothing is deleted.
        if SecKeychainItemSetAccess(ref as! SecKeychainItem, access) != errSecSuccess {
            gossipError("Could not update the Keychain access list for \(account)")
        }
    }
}
