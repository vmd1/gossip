import XCTest
import Security
@testable import Gossip

final class KeychainBlobStoreTests: XCTestCase {
    private var service: String!
    private let account = "test-blob"

    /// Whether the Keychain answers without anyone at the keyboard. A headless runner can block forever on an access
    /// prompt nobody sees (the test host does not see the runner's `CI` variable, so that cannot be the check); the probe
    /// runs on another thread and the tests skip if it has not come back after ten seconds. Decided once per run.
    private static let keychainAnswers: Bool = {
        let probe = "dev.vmd1.gossip.tests.probe.\(UUID().uuidString)"
        let done = DispatchSemaphore(value: 0)
        var ok = false
        DispatchQueue.global().async {
            ok = KeychainBlobStore(service: probe, account: "probe").write(Data("probe".utf8))
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: probe] as CFDictionary)
            done.signal()
        }
        return done.wait(timeout: .now() + 10) == .success && ok
    }()

    override func setUpWithError() throws {
        guard Self.keychainAnswers else { throw XCTSkip("Keychain not usable here (locked, headless, or waiting on a prompt)") }
        service = "dev.vmd1.gossip.tests.\(UUID().uuidString)"
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
