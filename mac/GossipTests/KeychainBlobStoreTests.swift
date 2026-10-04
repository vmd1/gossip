import XCTest
import Security
@testable import Gossip

final class KeychainBlobStoreTests: XCTestCase {
    private var dir: URL!
    private var service: String!
    private let account = "test-blob"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("kb-\(UUID().uuidString)")
        PrivateFile.ensureDirectory(dir)
        service = "dev.vmd1.gossip.tests.\(UUID().uuidString)"
        // Keychain access can be unavailable (headless runner, locked keychain): skip rather than fail.
        let probe = KeychainBlobStore(service: service, account: account, legacyFile: dir.appendingPathComponent("probe.json"))
        guard probe.write(Data("probe".utf8)), !FileManager.default.fileExists(atPath: dir.appendingPathComponent("probe.json").path) else {
            throw XCTSkip("Keychain not usable in this environment")
        }
        deleteItem()
    }

    override func tearDown() {
        deleteItem()
        try? FileManager.default.removeItem(at: dir)
    }

    private func deleteItem() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service as Any,
                       kSecAttrAccount as String: account] as CFDictionary)
    }

    func testWriteThenReadRoundTripsAndLeavesNoFile() {
        let legacy = dir.appendingPathComponent("blob.json")
        let store = KeychainBlobStore(service: service, account: account, legacyFile: legacy)
        XCTAssertTrue(store.write(Data("secret".utf8)))
        XCTAssertEqual(store.read(), Data("secret".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testLegacyFileIsMigratedIntoKeychainAndRemoved() throws {
        let legacy = dir.appendingPathComponent("blob.json")
        try Data("old-plaintext".utf8).write(to: legacy)
        let store = KeychainBlobStore(service: service, account: account, legacyFile: legacy)

        XCTAssertEqual(store.read(), Data("old-plaintext".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path), "plaintext copy must be deleted after migration")
        // A fresh instance now reads it from the Keychain alone.
        XCTAssertEqual(KeychainBlobStore(service: service, account: account, legacyFile: legacy).read(), Data("old-plaintext".utf8))
    }

    func testStaleLegacyFileIsRemovedWhenKeychainItemExists() throws {
        let legacy = dir.appendingPathComponent("blob.json")
        let store = KeychainBlobStore(service: service, account: account, legacyFile: legacy)
        XCTAssertTrue(store.write(Data("current".utf8)))
        try Data("stale".utf8).write(to: legacy)

        XCTAssertEqual(store.read(), Data("current".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testIdentityPersistsThroughKeychainBlob() {
        let blob = KeychainBlobStore(service: service, account: account, legacyFile: dir.appendingPathComponent("identity.json"))
        let first = IdentityKeyStore(blob: blob)
        let id = first.deviceId
        let key = first.signingKey.rawRepresentation
        let second = IdentityKeyStore(blob: KeychainBlobStore(service: service, account: account, legacyFile: dir.appendingPathComponent("identity.json")))
        XCTAssertEqual(second.deviceId, id)
        XCTAssertEqual(second.signingKey.rawRepresentation, key)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("identity.json").path))
    }
}
