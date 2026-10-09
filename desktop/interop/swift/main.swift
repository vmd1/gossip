// Line-oriented harness around the Mac app's real NoiseSession / Envelope / EnvelopeSigning sources, so the Rust
// core can be tested against the code that actually ships. Built by desktop/scripts/build-swift-interop.sh.
import Foundation
import CryptoKit

func unhex(_ s: String) -> Data {
    var data = Data(); var it = s.makeIterator()
    while let a = it.next(), let b = it.next() { data.append(UInt8(String([a, b]), radix: 16)!) }
    return data
}
func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

var session: NoiseSession?

while let line = readLine() {
    let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
    let cmd = parts[0]
    do {
        switch cmd {
        case "INIT":  // INIT <secretHex> <remotePubHex>
            let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: unhex(parts[1]))
            let remote = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: unhex(parts[2]))
            session = NoiseSession(role: .initiator, localStaticKey: key, remoteStaticKey: remote)
            print("OK")
        case "RESP":  // RESP <secretHex>
            let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: unhex(parts[1]))
            session = NoiseSession(role: .responder, localStaticKey: key, remoteStaticKey: nil)
            print("OK")
        case "M1": print(hex(try session!.createMessage1(payload: unhex(parts.count > 1 ? parts[1] : ""))))
        case "R1": print(hex(try session!.consumeMessage1(unhex(parts[1]))))
        case "M2": print(hex(try session!.createMessage2(payload: unhex(parts.count > 1 ? parts[1] : ""))))
        case "R2": print(hex(try session!.consumeMessage2(unhex(parts[1]))))
        case "ENC": print(hex(try session!.encrypt(unhex(parts.count > 1 ? parts[1] : ""))))
        case "DEC": print(hex(try session!.decrypt(unhex(parts[1]))))
        case "PEER": print(hex(session!.peerStaticKey!.rawRepresentation))
        case "SIGN":  // SIGN <seedHex> <envelope json>
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: unhex(parts[1]))
            let env = try Envelope.decode(Data(parts[2].utf8))
            let signed = try EnvelopeSigning.sign(env, with: key)
            print(String(data: try signed.encoded(), encoding: .utf8)!)
        case "VERIFY":  // VERIFY <pubHex> <envelope json>
            let pub = try Curve25519.Signing.PublicKey(rawRepresentation: unhex(parts[1]))
            let env = try Envelope.decode(Data(parts[2].utf8))
            print(EnvelopeSigning.verify(env, publicKey: pub) ? "true" : "false")
        case "CANON":  // CANON <envelope json>  -> hex of the signing bytes
            let env = try Envelope.decode(Data(line.dropFirst(6).utf8))
            print(hex(try EnvelopeSigning.signingBytes(env)))
        case "HSKEY":  // HSKEY <localX25519SecretHex> <remoteX25519PubHex>
            let local = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: unhex(parts[1]))
            let remote = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: unhex(parts[2]))
            let key = HotspotGattProtocol.deriveSharedSecretKey(localAgreementKey: local, remotePublicKey: remote)
            print(hex(key.withUnsafeBytes { Data($0) }))
        case "HSREQ_CREATE":  // HSREQ_CREATE <seedHex> <requesterId> <enable>
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: unhex(parts[1]))
            let rest = parts[2].split(separator: " ").map(String.init)
            let req = HotspotGattProtocol.ToggleRequestPayload.create(requesterId: rest[0], enable: rest[1] == "true", signingKey: key)
            print(String(data: HotspotGattProtocol.encodeRequest(req), encoding: .utf8)!)
        case "HSREQ_VERIFY":  // HSREQ_VERIFY <pubB64> <json>
            let req = HotspotGattProtocol.decodeRequest(Data(parts[2].utf8))
            print(req?.isSignatureValid(signingPublicKeyBase64: parts[1]) == true ? "true" : "false")
        case "HSSTATUS_CREATE":  // HSSTATUS_CREATE <seedHex> <providerId> <enabled> <nonce> <keyHex> <ssid> <pass>
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: unhex(parts[1]))
            let r = parts[2].split(separator: " ").map(String.init)
            let shared = SymmetricKey(data: unhex(r[3]))
            let status = HotspotGattProtocol.makeStatusPayload(providerId: r[0], enabled: r[1] == "true", nonce: r[2], signingKey: key,
                                                               sharedSecretKey: shared, ssid: r[4], passphrase: r[5])
            print(String(data: HotspotGattProtocol.encodeStatus(status), encoding: .utf8)!)
        case "HSSTATUS_VERIFY":  // HSSTATUS_VERIFY <pubB64> <keyHex> <json>
            let r = parts[2].split(separator: " ", maxSplits: 1).map(String.init)
            guard let status = HotspotGattProtocol.decodeStatus(Data(r[1].utf8)) else { print("false"); break }
            let valid = status.isSignatureValid(signingPublicKeyBase64: parts[1])
            let cred = status.decryptCredentials(sharedSecretKey: SymmetricKey(data: unhex(r[0])))
            print("\(valid) \(cred?.ssid ?? "-") \(cred?.passphrase ?? "-")")
        case "HSCHUNKS":  // HSCHUNKS <messageHex>
            print(HotspotGattProtocol.encodeChunks(unhex(parts.count > 1 ? parts[1] : "")).map(hex).joined(separator: ","))
        case "HSREASSEMBLE":  // HSREASSEMBLE <chunkHex,chunkHex,...>
            let reassembler = HotspotGattProtocol.ChunkReassembler()
            var result: Data?
            for c in parts[1].split(separator: ",") { result = reassembler.feed(unhex(String(c))) }
            print(result.map(hex) ?? "none")
        default: print("ERR unknown command")
        }
    } catch {
        print("ERR \(error)")
    }
    fflush(stdout)
}
