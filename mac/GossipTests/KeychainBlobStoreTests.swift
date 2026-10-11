import XCTest
import Security
@testable import Gossip

final class KeychainBlobStoreTests: XCTestCase {
    private var service: String!
    private let account = "test-blob"

    override func setUpWithError() throws {
        // A headless runner has no one to answer a Keychain access prompt, and the call would block until the job times out.
        if ProcessInfo.processInfo.environment["CI"] != nil { throw XCTSkip("no interactive Keychain on CI") }
        service = "dev.vmd1.gossip.tests.\(UUID().uuidString)"
        // Keychain access can be unavailable (headless runner, locked keychain): skip rather than fail.
        guard KeychainBlobStore(service: service, account: account).write(Data("probe".utf8)) else {
            throw XCTSkip("Keychain not usable in this environment")
        }
        deleteItem()
    }

    override func tearDown() { deleteItem() }

    private func deleteItem() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service as Any,
                       kSecAttrAccount as String: account] as CFDictionary)
    }

    func testWriteThenReadRoundTrips() {
        let store = KeychainBlobStore(service: service, account: account)
        XCTAssertNil(store.read())
        XCTAssertTrue(store.write(Data("secret".utf8)))
        XCTAssertEqual(store.read(), Data("secret".utf8))
        XCTAssertEqual(KeychainBlobStore(service: service, account: account).read(), Data("secret".utf8))
    }

    /// Changing an item's access list can make macOS show a prompt that takes about a minute to give up on, so this one
    /// runs only when asked for (`GOSSIP_KEYCHAIN_ACL_TEST=1`).
    func testAnItemWithTheOldAccessListIsUpgradedOnceAndStaysReadable() throws {
        guard ProcessInfo.processInfo.environment["GOSSIP_KEYCHAIN_ACL_TEST"] != nil else { throw XCTSkip("set GOSSIP_KEYCHAIN_ACL_TEST=1 to run") }
        // An item added the plain way, as earlier builds did, carries a partition list tied to one build's code hash.
        XCTAssertEqual(SecItemAdd([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service as Any,
                                   kSecAttrAccount as String: account, kSecValueData as String: Data("old".utf8)] as CFDictionary, nil), errSecSuccess)
        let defaults = UserDefaults(suiteName: "kb-\(UUID().uuidString)")!
        let store = KeychainBlobStore(service: service, account: account, defaults: defaults)
        XCTAssertEqual(store.read(), Data("old".utf8))
        XCTAssertTrue(defaults.bool(forKey: "keychain.accessUpgraded.\(service!).\(account)"))
        XCTAssertEqual(KeychainBlobStore(service: service, account: account, defaults: defaults).read(), Data("old".utf8))
        XCTAssertTrue(store.write(Data("new".utf8)))
        XCTAssertEqual(store.read(), Data("new".utf8))
    }

    func testIdentityPersistsThroughKeychainBlob() {
        let first = IdentityKeyStore(blob: KeychainBlobStore(service: service, account: account))
        let id = first.deviceId
        let key = first.signingKey.rawRepresentation
        let second = IdentityKeyStore(blob: KeychainBlobStore(service: service, account: account))
        XCTAssertEqual(second.deviceId, id)
        XCTAssertEqual(second.signingKey.rawRepresentation, key)
    }
}
