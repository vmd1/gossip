import Foundation
import CryptoKit

enum PairingCode {
    /// A short code both devices derive from the two Noise static keys, shown on both
    /// screens during pairing so the user can see they are talking to each other.
    /// Order-independent. Android implements the same function (`PairingCode.kt`).
    static func make(_ a: Data, _ b: Data) -> String {
        let (lo, hi) = a.lexicographicallyPrecedes(b) ? (a, b) : (b, a)
        var input = Data("gossip-pairing-code-v1".utf8)
        input.append(lo)
        input.append(hi)
        let digest = Array(SHA256.hash(data: input))
        let value = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        let s = String(format: "%06u", value)
        return "\(s.prefix(3)) \(s.suffix(3))"
    }

    /// Whether what the user typed is the displayed code (spaces and other separators ignored).
    static func entryMatches(_ entry: String, expected: String) -> Bool {
        let digits = { (s: String) in s.filter(\.isNumber) }
        let typed = digits(entry), want = digits(expected)
        return want.count == 6 && typed == want
    }

    /// Constant-time token comparison; nil on either side never matches.
    static func tokenMatches(armed: String?, presented: String?) -> Bool {
        guard let armed, let presented else { return false }
        let a = Array(armed.utf8), b = Array(presented.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }
}
