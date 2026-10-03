import Foundation
import CryptoKit

/// End-to-end authentication of an envelope's origin. Every envelope except the
/// `handshake.*` pair carries `sig`, an Ed25519 signature by `senderId`'s signing key over
/// the envelope's canonical form, so a relay (or anyone on the path) can't forge or
/// re-target a message "from" another device. `ttl` is excluded because every relaying hop
/// decrements it. Android has the same canonicalisation (`EnvelopeSigning.kt`); both are
/// checked against `schema/envelope-signing-vectors.json`. See `docs/wire-protocol.md`.
enum EnvelopeSigning {
    static let domain = "gossip-envelope-v1\n"

    enum CanonicalError: Error { case unsupportedNumber }

    /// The exact bytes that get signed.
    static func signingBytes(_ e: Envelope) throws -> Data {
        var out = Data(domain.utf8)
        out.append(try canonicalObject(e))
        return out
    }

    static func canonicalObject(_ e: Envelope) throws -> Data {
        let fields: [String: JSONValue] = [
            "v": .number(Double(e.v)),
            "id": .string(e.id),
            "type": .string(e.type),
            "senderId": .string(e.senderId),
            "recipientId": e.recipientId.map { .string($0) } ?? .null,
            "broadcast": .bool(e.broadcast),
            "hasRawFollowup": .bool(e.hasRawFollowup),
            "ts": .number(Double(e.ts)),
            "payload": e.payload
        ]
        var out = Data()
        try canonical(.object(fields), into: &out)
        return out
    }

    /// Canonical JSON: object keys sorted by UTF-8 bytes, no whitespace, integers only
    /// (payloads never carry fractions), strings escape only `"`, `\` and control characters (`\b\t\n\f\r` short, others `\u00xx`).
    static func canonical(_ value: JSONValue, into out: inout Data) throws {
        switch value {
        case .null: out.append(contentsOf: "null".utf8)
        case .bool(let b): out.append(contentsOf: (b ? "true" : "false").utf8)
        case .number(let n):
            guard n == n.rounded(), abs(n) < 9_007_199_254_740_992 else { throw CanonicalError.unsupportedNumber }
            out.append(contentsOf: String(Int64(n)).utf8)
        case .string(let s): appendString(s, into: &out)
        case .array(let items):
            out.append(0x5b)
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(0x2c) }
                try canonical(item, into: &out)
            }
            out.append(0x5d)
        case .object(let dict):
            out.append(0x7b)
            let keys = dict.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
            for (i, key) in keys.enumerated() {
                if i > 0 { out.append(0x2c) }
                appendString(key, into: &out)
                out.append(0x3a)
                try canonical(dict[key]!, into: &out)
            }
            out.append(0x7d)
        }
    }

    private static func appendString(_ s: String, into out: inout Data) {
        out.append(0x22)
        for byte in s.utf8 {
            switch byte {
            case 0x22: out.append(contentsOf: "\\\"".utf8)
            case 0x5c: out.append(contentsOf: "\\\\".utf8)
            case 0x08: out.append(contentsOf: "\\b".utf8)
            case 0x09: out.append(contentsOf: "\\t".utf8)
            case 0x0a: out.append(contentsOf: "\\n".utf8)
            case 0x0c: out.append(contentsOf: "\\f".utf8)
            case 0x0d: out.append(contentsOf: "\\r".utf8)
            case 0..<0x20: out.append(contentsOf: String(format: "\\u%04x", byte).utf8)
            default: out.append(byte)
            }
        }
        out.append(0x22)
    }

    static func sign(_ e: Envelope, with key: Curve25519.Signing.PrivateKey) throws -> Envelope {
        let signature = try key.signature(for: signingBytes(e))
        return e.withSignature(signature.base64EncodedString())
    }

    static func verify(_ e: Envelope, publicKey: Curve25519.Signing.PublicKey) -> Bool {
        guard let sig = e.sig, let sigData = Data(base64Encoded: sig),
              let bytes = try? signingBytes(e) else { return false }
        return publicKey.isValidSignature(sigData, for: bytes)
    }
}
