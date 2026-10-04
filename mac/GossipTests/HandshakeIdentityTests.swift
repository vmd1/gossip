import XCTest
@testable import Gossip

final class HandshakeIdentityTests: XCTestCase {
    private let key = Data((0..<32).map { UInt8($0) }).base64EncodedString()
    private let id = "11111111-1111-1111-1111-111111111111"

    func testRoundTripsWithAndWithoutToken() throws {
        let with = HandshakeIdentity(deviceId: id, deviceName: "Mac", deviceType: "mac", signingPublicKey: key, pairingToken: "tok")
        XCTAssertEqual(try HandshakeIdentity.decode(try with.encoded()), with)
        let without = HandshakeIdentity(deviceId: id, deviceName: "Mac", deviceType: "mac", signingPublicKey: key, pairingToken: nil)
        XCTAssertNil(try HandshakeIdentity.decode(try without.encoded()).pairingToken)
    }

    func testRejectsMalformedIdentity() throws {
        let badId = HandshakeIdentity(deviceId: "nope", deviceName: "m", deviceType: "mac", signingPublicKey: key, pairingToken: nil)
        XCTAssertThrowsError(try HandshakeIdentity.decode(try badId.encoded()))
        let badKey = HandshakeIdentity(deviceId: id, deviceName: "m", deviceType: "mac", signingPublicKey: "AAAA", pairingToken: nil)
        XCTAssertThrowsError(try HandshakeIdentity.decode(try badKey.encoded()))
    }

    func testPairingCodeMatchesAndroidVectorAndIgnoresOrder() {
        let a = Data((0..<32).map { UInt8($0) })
        let b = Data((32..<64).map { UInt8($0) })
        XCTAssertEqual(PairingCode.make(a, b), "977 657")
        XCTAssertEqual(PairingCode.make(b, a), "977 657")
    }

    func testTokenComparison() {
        XCTAssertTrue(PairingCode.tokenMatches(armed: "abc", presented: "abc"))
        XCTAssertFalse(PairingCode.tokenMatches(armed: "abc", presented: "abd"))
        XCTAssertFalse(PairingCode.tokenMatches(armed: "abc", presented: "ab"))
        XCTAssertFalse(PairingCode.tokenMatches(armed: nil, presented: "abc"))
        XCTAssertFalse(PairingCode.tokenMatches(armed: "abc", presented: nil))
    }

    func testTombstonePersistsAndPairingAgainClearsIt() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tomb-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-revoked.json"))
        }
        let store = TrustedDevicesStore(fileURL: url)
        store.addDevice(deviceId: id, publicKeyBase64: "k", deviceName: "d", deviceType: .androidPhone)
        store.revoke(deviceId: id, revokedAt: 500)
        store.revoke(deviceId: id, revokedAt: 300)
        XCTAssertEqual(store.revokedAt(deviceId: id), 500)

        let reloaded = TrustedDevicesStore(fileURL: url)
        XCTAssertEqual(reloaded.revokedAt(deviceId: id), 500)
        reloaded.addDevice(deviceId: id, publicKeyBase64: "k", deviceName: "d", deviceType: .androidPhone)
        XCTAssertNil(reloaded.revokedAt(deviceId: id))
    }

    func testHandshakeSigningKeyReplacesGossipedValue() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sk-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = TrustedDevicesStore(fileURL: url)
        store.addDevice(deviceId: id, publicKeyBase64: "k", deviceName: "d", deviceType: .androidPhone, signingPublicKeyBase64: "gossiped")
        store.setSigningPublicKey(deviceId: id, signingPublicKeyBase64: "authentic")
        XCTAssertEqual(store.device(for: id)?.signingPublicKeyBase64, "authentic")
    }
}

final class HostValidatorTests: XCTestCase {
    func testAcceptsAddressesAndHostnames() {
        for h in ["192.168.0.5", "100.64.1.2", "fe80::1", "fe80::1%en0", "2001:db8::ff00:42:8329", "tablet", "my-mac.tail1234.ts.net"] {
            XCTAssertTrue(HostValidator.isValid(h), h)
        }
    }

    func testRejectsEverythingElse() {
        for h in ["", " ", "256.1.1.1", "1.2.3", "host:7913", "http://x", "a b", "x/y", "-bad.example", "bad-.example", "a..b",
                  "fe80::zz", "fe80::1%", "::1::2", String(repeating: "x", count: 64) + ".com", "exa_mple.com", "例え.jp"] {
            XCTAssertFalse(HostValidator.isValid(h), h)
        }
    }

    func testStoreRefusesInvalidFallbackHostAndKeepsTheOldOne() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fb-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = TrustedDevicesStore(fileURL: url)
        store.addDevice(deviceId: "a", publicKeyBase64: "k", deviceName: "d", deviceType: .mac)
        XCTAssertTrue(store.setFallbackHost(deviceId: "a", fallbackHost: "10.0.0.2"))
        XCTAssertFalse(store.setFallbackHost(deviceId: "a", fallbackHost: "http://evil"))
        XCTAssertEqual(store.device(for: "a")?.fallbackHost, "10.0.0.2")
        XCTAssertTrue(store.setFallbackHost(deviceId: "a", fallbackHost: "  "))
        XCTAssertNil(store.device(for: "a")?.fallbackHost)
    }
}
