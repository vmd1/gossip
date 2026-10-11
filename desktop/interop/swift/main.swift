// Line-oriented harness around the Mac app's real Envelope / EnvelopeSigning sources, so the Rust
// core can be tested against the code that actually ships. Built by desktop/scripts/build-swift-interop.sh.
import Foundation
import CryptoKit

func unhex(_ s: String) -> Data {
    var data = Data(); var it = s.makeIterator()
    while let a = it.next(), let b = it.next() { data.append(UInt8(String([a, b]), radix: 16)!) }
    return data
}
func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

while let line = readLine() {
    let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
    let cmd = parts[0]
    do {
        switch cmd {
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
        default: print("ERR unknown command")
        }
    } catch {
        print("ERR \(error)")
    }
    fflush(stdout)
}
