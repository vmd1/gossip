import Foundation
import CryptoKit

/// Platform-neutral wire format of the Universal Control data channel (Mac -> Android device).
/// The Kotlin twin is `ControlProtocol.kt`; both are checked against `schema/control-test-vectors.json`.
///
/// Transport: a WebSocket straight to the device (never the mesh). Every WebSocket message is one
/// encrypted frame:
///
///     [u64 BE counter][ChaCha20-Poly1305 ciphertext][16-byte tag]
///
/// - Keys: HKDF-SHA256(ikm: the 32-byte `secret` from `control.session_start`, salt: the UTF-8
///   `sessionId`, info: `"gossip-control-v1 m2d"` / `"gossip-control-v1 d2m"`), one key per direction.
/// - Nonce: 4 zero bytes + the counter. Each direction's counter strictly increases (starting at 1); a
///   receiver drops any frame whose counter is not greater than the last accepted one, which also makes
///   a replayed or duplicated frame harmless.
/// - AAD: `"gossip-control-v1"` + direction byte (1 = m2d, 2 = d2m) + UTF-8 `sessionId`.
///
/// The decrypted plaintext is `[u8 kind][payload]`, see `ControlFrame`.
enum ControlDirection: UInt8 {
    case macToDevice = 1
    case deviceToMac = 2

    var hkdfInfo: Data {
        Data((self == .macToDevice ? "gossip-control-v1 m2d" : "gossip-control-v1 d2m").utf8)
    }
}

/// Screen edge, from the point of view of the screen the cursor enters or leaves through.
enum ControlEdge: UInt8, Equatable, Codable, CaseIterable {
    case left = 0, right = 1, top = 2, bottom = 3

    var opposite: ControlEdge {
        switch self {
        case .left: return .right
        case .right: return .left
        case .top: return .bottom
        case .bottom: return .top
        }
    }
}

/// What the device reports about itself on connect and on rotation: its logical (rotation-applied) size.
struct ControlDisplayInfo: Equatable, Codable {
    var width: Int
    var height: Int
    /// 0...3, quarter turns clockwise.
    var rotation: Int
    /// Which input backend the device is using (`ControlBackendKind` raw value).
    var backend: Int
}

enum ControlBackendKind: Int {
    case uhid = 0
    case touchOverlay = 1
}

enum ControlFrame: Equatable {
    // Mac -> device
    case hello(sessionId: String)
    /// The cursor enters the device through `edge`, `position` (0...65535) of the way along that edge.
    case enter(edge: ControlEdge, position: UInt16)
    case leave
    case mouseMove(dx: Int16, dy: Int16)
    /// Bit 0 = primary, 1 = secondary, 2 = middle, 3 = back, 4 = forward.
    case buttons(UInt8)
    /// Scroll in 1/120 of a notch (like the Windows wheel delta); positive y = up, positive x = right.
    case scroll(dx: Int16, dy: Int16)
    /// `usage` is a USB HID keyboard-page usage; `modifiers` the HID modifier bitmask (LCtrl=1, LShift=2,
    /// LAlt=4, LMeta=8, RCtrl=16, RShift=32, RAlt=64, RMeta=128).
    case key(usage: UInt16, down: Bool, modifiers: UInt8)
    case text(String)
    case ping
    /// Asks the device where its real cursor is; answered with `cursorPos` carrying the same `token`.
    case cursorQuery(token: UInt8)
    // device -> Mac
    case helloAck(ControlDisplayInfo)
    case displayInfo(ControlDisplayInfo)
    case error(String)
    case pong
    /// The device's real cursor position in its own logical pixels, and how many `mouseMove` frames it had
    /// applied (since the last `enter`) when it was read, so the Mac can compare it with the model at that moment.
    case cursorPos(token: UInt8, x: UInt16, y: UInt16, applied: UInt32)

    enum Kind {
        static let hello: UInt8 = 0x01
        static let enter: UInt8 = 0x10
        static let leave: UInt8 = 0x11
        static let mouseMove: UInt8 = 0x12
        static let buttons: UInt8 = 0x13
        static let scroll: UInt8 = 0x14
        static let key: UInt8 = 0x15
        static let text: UInt8 = 0x16
        static let ping: UInt8 = 0x17
        static let cursorQuery: UInt8 = 0x18
        static let helloAck: UInt8 = 0x81
        static let displayInfo: UInt8 = 0x82
        static let error: UInt8 = 0x84
        static let pong: UInt8 = 0x85
        static let cursorPos: UInt8 = 0x86
    }

    func encoded() -> Data {
        var w = ByteWriter()
        switch self {
        case .hello(let id): w.u8(Kind.hello); w.bytes(Data(id.utf8))
        case .enter(let edge, let pos): w.u8(Kind.enter); w.u8(edge.rawValue); w.u16(pos)
        case .leave: w.u8(Kind.leave)
        case .mouseMove(let dx, let dy): w.u8(Kind.mouseMove); w.i16(dx); w.i16(dy)
        case .buttons(let mask): w.u8(Kind.buttons); w.u8(mask)
        case .scroll(let dx, let dy): w.u8(Kind.scroll); w.i16(dx); w.i16(dy)
        case .key(let usage, let down, let mods): w.u8(Kind.key); w.u16(usage); w.u8(down ? 1 : 0); w.u8(mods)
        case .text(let s): w.u8(Kind.text); w.bytes(Data(s.utf8))
        case .ping: w.u8(Kind.ping)
        case .cursorQuery(let t): w.u8(Kind.cursorQuery); w.u8(t)
        case .helloAck(let d): w.u8(Kind.helloAck); w.display(d)
        case .displayInfo(let d): w.u8(Kind.displayInfo); w.display(d)
        case .error(let s): w.u8(Kind.error); w.bytes(Data(s.utf8))
        case .pong: w.u8(Kind.pong)
        case .cursorPos(let t, let x, let y, let n): w.u8(Kind.cursorPos); w.u8(t); w.u16(x); w.u16(y); w.u32(n)
        }
        return w.data
    }

    static func decode(_ data: Data) -> ControlFrame? {
        var r = ByteReader(data)
        guard let kind = r.u8() else { return nil }
        switch kind {
        case Kind.hello: return r.rest().flatMap { String(data: $0, encoding: .utf8) }.map { .hello(sessionId: $0) }
        case Kind.enter:
            guard let e = r.u8(), let edge = ControlEdge(rawValue: e), let p = r.u16(), r.isAtEnd else { return nil }
            return .enter(edge: edge, position: p)
        case Kind.leave: return r.isAtEnd ? .leave : nil
        case Kind.mouseMove:
            guard let dx = r.i16(), let dy = r.i16(), r.isAtEnd else { return nil }
            return .mouseMove(dx: dx, dy: dy)
        case Kind.buttons:
            guard let m = r.u8(), r.isAtEnd else { return nil }
            return .buttons(m)
        case Kind.scroll:
            guard let dx = r.i16(), let dy = r.i16(), r.isAtEnd else { return nil }
            return .scroll(dx: dx, dy: dy)
        case Kind.key:
            guard let u = r.u16(), let d = r.u8(), let m = r.u8(), r.isAtEnd, d <= 1 else { return nil }
            return .key(usage: u, down: d == 1, modifiers: m)
        case Kind.text: return r.rest().flatMap { String(data: $0, encoding: .utf8) }.map { .text($0) }
        case Kind.ping: return r.isAtEnd ? .ping : nil
        case Kind.cursorQuery:
            guard let t = r.u8(), r.isAtEnd else { return nil }
            return .cursorQuery(token: t)
        case Kind.helloAck: return r.display().map { .helloAck($0) }
        case Kind.displayInfo: return r.display().map { .displayInfo($0) }
        case Kind.error: return r.rest().flatMap { String(data: $0, encoding: .utf8) }.map { .error($0) }
        case Kind.pong: return r.isAtEnd ? .pong : nil
        case Kind.cursorPos:
            guard let t = r.u8(), let x = r.u16(), let y = r.u16(), let n = r.u32(), r.isAtEnd else { return nil }
            return .cursorPos(token: t, x: x, y: y, applied: n)
        default: return nil
        }
    }
}

/// Encrypts/decrypts frames for one end of a session. Not thread-safe; owned by one queue.
struct ControlCipher {
    enum Failure: Error { case badLength, replayed, authentication }

    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private let sendDirection: ControlDirection
    private let sessionIdData: Data
    private(set) var sendCounter: UInt64 = 0
    private(set) var lastReceivedCounter: UInt64 = 0

    /// `role` is this end's role: the Mac sends m2d and receives d2m.
    init(secret: Data, sessionId: String, role: ControlDirection) {
        sessionIdData = Data(sessionId.utf8)
        func key(_ d: ControlDirection) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: Data(sessionId.utf8), info: d.hkdfInfo, outputByteCount: 32)
        }
        let other: ControlDirection = role == .macToDevice ? .deviceToMac : .macToDevice
        sendKey = key(role)
        receiveKey = key(other)
        sendDirection = role
    }

    private func aad(_ d: ControlDirection) -> Data {
        var a = Data("gossip-control-v1".utf8)
        a.append(d.rawValue)
        a.append(sessionIdData)
        return a
    }

    private static func nonce(_ counter: UInt64) throws -> ChaChaPoly.Nonce {
        var n = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { n.append(contentsOf: $0) }
        return try ChaChaPoly.Nonce(data: n)
    }

    mutating func seal(_ frame: ControlFrame) throws -> Data {
        sendCounter += 1
        return try seal(plaintext: frame.encoded(), counter: sendCounter)
    }

    /// Exposed for the shared test vectors (fixed counter).
    func seal(plaintext: Data, counter: UInt64) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: Self.nonce(counter), authenticating: aad(sendDirection))
        var out = Data()
        withUnsafeBytes(of: counter.bigEndian) { out.append(contentsOf: $0) }
        out.append(box.ciphertext)
        out.append(box.tag)
        return out
    }

    mutating func open(_ message: Data) throws -> ControlFrame? {
        guard message.count >= 8 + 16 else { throw Failure.badLength }
        let base = message.startIndex
        var counter: UInt64 = 0
        for i in 0..<8 { counter = (counter << 8) | UInt64(message[base + i]) }
        guard counter > lastReceivedCounter else { throw Failure.replayed }
        let ciphertext = message[(base + 8)..<(message.endIndex - 16)]
        let tag = message[(message.endIndex - 16)...]
        let receiveDirection: ControlDirection = sendDirection == .macToDevice ? .deviceToMac : .macToDevice
        let plaintext: Data
        do {
            let box = try ChaChaPoly.SealedBox(nonce: Self.nonce(counter), ciphertext: ciphertext, tag: tag)
            plaintext = try ChaChaPoly.open(box, using: receiveKey, authenticating: aad(receiveDirection))
        } catch {
            throw Failure.authentication
        }
        lastReceivedCounter = counter // only after authentication, so garbage can't burn counters
        return ControlFrame.decode(plaintext)
    }
}

// MARK: - Byte helpers

struct ByteWriter {
    private(set) var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { data.append(UInt8(v >> 8)); data.append(UInt8(v & 0xff)) }
    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    mutating func u32(_ v: UInt32) { u16(UInt16(v >> 16)); u16(UInt16(v & 0xffff)) }
    mutating func bytes(_ d: Data) { data.append(d) }
    mutating func display(_ d: ControlDisplayInfo) {
        u16(UInt16(clamping: d.width)); u16(UInt16(clamping: d.height))
        u8(UInt8(clamping: d.rotation)); u8(UInt8(clamping: d.backend))
    }
}

struct ByteReader {
    private let data: Data
    private var index: Data.Index
    init(_ data: Data) { self.data = data; index = data.startIndex }
    var isAtEnd: Bool { index == data.endIndex }
    mutating func u8() -> UInt8? {
        guard index < data.endIndex else { return nil }
        defer { index = data.index(after: index) }
        return data[index]
    }
    mutating func u16() -> UInt16? {
        guard let a = u8(), let b = u8() else { return nil }
        return UInt16(a) << 8 | UInt16(b)
    }
    mutating func i16() -> Int16? { u16().map { Int16(bitPattern: $0) } }
    mutating func u32() -> UInt32? {
        guard let a = u16(), let b = u16() else { return nil }
        return UInt32(a) << 16 | UInt32(b)
    }
    mutating func rest() -> Data? {
        defer { index = data.endIndex }
        return Data(data[index...])
    }
    mutating func display() -> ControlDisplayInfo? {
        guard let w = u16(), let h = u16(), let r = u8(), let b = u8(), isAtEnd else { return nil }
        return ControlDisplayInfo(width: Int(w), height: Int(h), rotation: Int(r), backend: Int(b))
    }
}
