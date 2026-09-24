import Foundation

/// The wire-protocol JSON envelope shared by every message exchanged between
/// trusted devices once a Noise session has been established.
///
/// Framing (applied by `TransportManager`): `[4-byte big-endian length][payload]`
/// where `payload` is Noise-encrypted ciphertext. The decrypted plaintext is
/// exactly the JSON encoding of this struct.
struct Envelope: Codable, Equatable {
    /// Protocol version.
    let v: Int
    /// UUIDv4 identifying this specific message.
    let id: String
    /// Dotted namespace.action string, e.g. "presence.online".
    let type: String
    /// Device UUID of the sender.
    let senderId: String
    /// Device UUID of the intended recipient, or nil when not directed at a single device.
    let recipientId: String?
    /// True when this message should be treated as a broadcast to all trusted devices.
    let broadcast: Bool
    /// Hop budget for flood-forwarding across the mesh: set to `Envelope.defaultTTL`
    /// by the originating sender, decremented by 1 at every relaying hop (a device
    /// forwarding an envelope it did not originate), dropped (not forwarded further)
    /// once it reaches 0. See `docs/wire-protocol.md`'s "Multi-hop relay" section.
    let ttl: Int
    /// When `true`, this envelope's metadata is immediately followed on the wire by a
    /// second, raw (non-envelope) Noise-encrypted frame — the "large binary payload"
    /// convention in `docs/wire-protocol.md` (e.g. clipboard image sync). Relayed
    /// hop-by-hop atomically alongside the envelope itself: a relaying device always
    /// forwards the metadata and its raw frame together, never the metadata alone. See
    /// `TransportManager.handleReceivedEnvelope`.
    let hasRawFollowup: Bool
    /// Milliseconds since Unix epoch.
    let ts: Int64
    /// Arbitrary, type-specific payload.
    let payload: JSONValue

    /// Default hop budget for an originating send — generous relative to any
    /// realistically-sized mesh of a handful of devices.
    static let defaultTTL = 8

    init(
        id: String = UUID().uuidString,
        type: String,
        senderId: String,
        recipientId: String? = nil,
        broadcast: Bool = false,
        ttl: Int = Envelope.defaultTTL,
        hasRawFollowup: Bool = false,
        ts: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        payload: JSONValue = .object([:])
    ) {
        self.v = 1
        self.id = id
        self.type = type
        self.senderId = senderId
        self.recipientId = recipientId
        self.broadcast = broadcast
        self.ttl = ttl
        self.hasRawFollowup = hasRawFollowup
        self.ts = ts
        self.payload = payload
    }

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func decode(_ data: Data) throws -> Envelope {
        try JSONDecoder().decode(Envelope.self, from: data)
    }

    /// A copy of this envelope with `ttl` replaced — used when forwarding/relaying
    /// (never when originating; originators use `Envelope.defaultTTL` via `init`).
    func withTTL(_ newTTL: Int) -> Envelope {
        Envelope(
            id: id, type: type, senderId: senderId, recipientId: recipientId,
            broadcast: broadcast, ttl: newTTL, hasRawFollowup: hasRawFollowup, ts: ts, payload: payload
        )
    }

    /// Namespace portion of `type`, e.g. "presence" for "presence.online".
    var namespace: String {
        String(type.split(separator: ".", maxSplits: 1).first ?? "")
    }
}

/// A minimal untyped JSON value so `Envelope.payload` can carry arbitrary
/// message-specific data while staying `Codable` without external dependencies.
indirect enum JSONValue: Codable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let dict = try? container.decode([String: JSONValue].self) {
            self = .object(dict)
        } else if let arr = try? container.decode([JSONValue].self) {
            self = .array(arr)
        } else if let str = try? container.decode(String.self) {
            self = .string(str)
        } else if let num = try? container.decode(Double.self) {
            self = .number(num)
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if container.decodeNil() {
            self = .null
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let dict): try container.encode(dict)
        case .array(let arr): try container.encode(arr)
        case .string(let str): try container.encode(str)
        case .number(let num): try container.encode(num)
        case .bool(let b): try container.encode(b)
        case .null: try container.encodeNil()
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var numberValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
}
