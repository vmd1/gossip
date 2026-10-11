import XCTest
import Security
@testable import Gossip

final class KeychainBlobStoreTests: XCTestCase {
    private var service: String!
    private let account = "test-blob"

    override func setUpWithError() throws {
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

    func testIdentityPersistsThroughKeychainBlob() {
        let first = IdentityKeyStore(blob: KeychainBlobStore(service: service, account: account))
        let id = first.deviceId
        let key = first.signingKey.rawRepresentation
        let second = IdentityKeyStore(blob: KeychainBlobStore(service: service, account: account))
        XCTAssertEqual(second.deviceId, id)
        XCTAssertEqual(second.signingKey.rawRepresentation, key)
    }
}
