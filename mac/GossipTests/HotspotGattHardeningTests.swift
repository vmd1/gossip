import XCTest
import CryptoKit
@testable import Gossip

final class HotspotGattHardeningTests: XCTestCase {
    func testRequestCarriesASignedTimestamp() {
        let key = Curve25519.Signing.PrivateKey()
        let request = HotspotGattProtocol.ToggleRequestPayload.create(requesterId: "dev", enable: true, signingKey: key)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        XCTAssertLessThan(abs(now - request.t), 5_000)
        let pub = key.publicKey.rawRepresentation.base64EncodedString()
        XCTAssertTrue(request.isSignatureValid(signingPublicKeyBase64: pub))

        // Changing the timestamp (replaying under a fresh one) breaks the signature.
        let moved = HotspotGattProtocol.ToggleRequestPayload(id: request.id, en: request.en, n: request.n, t: request.t + 1, s: request.s)
        XCTAssertFalse(moved.isSignatureValid(signingPublicKeyBase64: pub))
    }

    func testReassemblyDropsOversizedMessagesAndRecovers() {
        let r = HotspotGattProtocol.ChunkReassembler()
        var result: Data? = Data([9])
        for chunk in HotspotGattProtocol.encodeChunks(Data(repeating: 1, count: HotspotGattProtocol.maxMessageBytes + 50)) { result = r.feed(chunk) }
        XCTAssertNil(result)
        var out: Data?
        let ok = Data(repeating: 2, count: 30)
        for chunk in HotspotGattProtocol.encodeChunks(ok) { out = r.feed(chunk) }
        XCTAssertEqual(out, ok)
    }
}
