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
    /// Milliseconds since Unix epoch.
    let ts: Int64
    /// Arbitrary, type-specific payload.
    let payload: JSONValue

    init(
        id: String = UUID().uuidString,
        type: String,
        senderId: String,
        recipientId: String? = nil,
        broadcast: Bool = false,
        ts: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        payload: JSONValue = .object([:])
    ) {
        self.v = 1
        self.id = id
        self.type = type
        self.senderId = senderId
        self.recipientId = recipientId
        self.broadcast = broadcast
        self.ts = ts
        self.payload = payload
    }

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func decode(_ data: Data) throws -> Envelope {
        try JSONDecoder().decode(Envelope.self, from: data)
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
}
