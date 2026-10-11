import Foundation
import CryptoKit
import GossipCoreKit

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

/// Device navigation actions, triggered by the Mac-side shortcuts (⌘1 / ⌘2 / ⌘3 / ⌘[, like screen mirroring).
enum ControlAction: UInt8, CaseIterable {
    case home = 1, appSwitch = 2, notifications = 3, back = 4

    /// The action bound to ⌘ + this Mac key code (1, 2, 3 and [), the same bindings as screen mirroring.
    static func shortcut(forMacKeyCode code: UInt16) -> ControlAction? {
        switch code {
        case 18: return .home          // 1
        case 19: return .appSwitch     // 2
        case 20: return .notifications // 3
        case 33: return .back          // [
        default: return nil
        }
    }
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
    /// A system navigation action on the device (`ControlAction` raw value): Home, App Switcher, Notifications, Back.
    case action(ControlAction)
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
        static let action: UInt8 = 0x19
        static let helloAck: UInt8 = 0x81
        static let displayInfo: UInt8 = 0x82
        static let error: UInt8 = 0x84
        static let pong: UInt8 = 0x85
        static let cursorPos: UInt8 = 0x86
    }

    /// The wire bytes; the codec is the core's (`desktop/core/src/features/control.rs`), shared with every platform.
    func encoded() -> Data { Data(GossipCoreKit.controlFrameEncode(frame: core)) }

    static func decode(_ data: Data) -> ControlFrame? {
        GossipCoreKit.controlFrameDecode(data: data).map(ControlFrame.init(core:))
    }

    private var core: GossipCoreKit.ControlFrame {
        func info(_ d: ControlDisplayInfo) -> GossipCoreKit.ControlDisplayInfo {
            GossipCoreKit.ControlDisplayInfo(width: UInt16(clamping: d.width), height: UInt16(clamping: d.height),
                                             rotation: UInt8(clamping: d.rotation), backend: UInt8(clamping: d.backend))
        }
        switch self {
        case .hello(let id): return .hello(sessionId: id)
        case .enter(let edge, let pos): return .enter(edge: edge.core, position: pos)
        case .leave: return .leave
        case .mouseMove(let dx, let dy): return .mouseMove(dx: dx, dy: dy)
        case .buttons(let mask): return .buttons(mask: mask)
        case .scroll(let dx, let dy): return .scroll(dx: dx, dy: dy)
        case .key(let usage, let down, let mods): return .key(usage: usage, down: down, modifiers: mods)
        case .text(let s): return .text(text: s)
        case .ping: return .ping
        case .cursorQuery(let t): return .cursorQuery(token: t)
        case .action(let a): return .action(action: a.core)
        case .helloAck(let d): return .helloAck(info: info(d))
        case .displayInfo(let d): return .displayInfo(info: info(d))
        case .error(let s): return .error(reason: s)
        case .pong: return .pong
        case .cursorPos(let t, let x, let y, let n): return .cursorPos(token: t, x: x, y: y, applied: n)
        }
    }

    private init(core: GossipCoreKit.ControlFrame) {
        func info(_ d: GossipCoreKit.ControlDisplayInfo) -> ControlDisplayInfo {
            ControlDisplayInfo(width: Int(d.width), height: Int(d.height), rotation: Int(d.rotation), backend: Int(d.backend))
        }
        switch core {
        case .hello(let id): self = .hello(sessionId: id)
        case .enter(let edge, let pos): self = .enter(edge: ControlEdge(core: edge), position: pos)
        case .leave: self = .leave
        case .mouseMove(let dx, let dy): self = .mouseMove(dx: dx, dy: dy)
        case .buttons(let mask): self = .buttons(mask)
        case .scroll(let dx, let dy): self = .scroll(dx: dx, dy: dy)
        case .key(let usage, let down, let mods): self = .key(usage: usage, down: down, modifiers: mods)
        case .text(let s): self = .text(s)
        case .ping: self = .ping
        case .cursorQuery(let t): self = .cursorQuery(token: t)
        case .action(let a): self = .action(ControlAction(core: a))
        case .helloAck(let d): self = .helloAck(info(d))
        case .displayInfo(let d): self = .displayInfo(info(d))
        case .error(let s): self = .error(s)
        case .pong: self = .pong
        case .cursorPos(let t, let x, let y, let n): self = .cursorPos(token: t, x: x, y: y, applied: n)
        }
    }
}

extension ControlEdge {
    fileprivate var core: GossipCoreKit.ControlEdge {
        switch self { case .left: return .left; case .right: return .right; case .top: return .top; case .bottom: return .bottom }
    }
    fileprivate init(core: GossipCoreKit.ControlEdge) {
        switch core { case .left: self = .left; case .right: self = .right; case .top: self = .top; case .bottom: self = .bottom }
    }
}

extension ControlAction {
    fileprivate var core: GossipCoreKit.ControlAction {
        switch self { case .home: return .home; case .appSwitch: return .appSwitch; case .notifications: return .notifications; case .back: return .back }
    }
    fileprivate init(core: GossipCoreKit.ControlAction) {
        switch core { case .home: self = .home; case .appSwitch: self = .appSwitch; case .notifications: self = .notifications; case .back: self = .back }
    }
}

/// Encrypts/decrypts frames for one end of a session. The construction is the core's `StreamCipher`
/// (`desktop/core/src/crypto/stream.rs`), shared with every platform. Owned by one queue.
struct ControlCipher {
    enum Failure: Error { case badLength, replayed, authentication }

    private let inner: GossipCoreKit.StreamCipher

    /// `role` is this end's role: the Mac sends m2d and receives d2m.
    init(secret: Data, sessionId: String, role: ControlDirection) {
        inner = GossipCoreKit.StreamCipher(profile: .control, secret: secret, sessionId: sessionId, firstEnd: role == .macToDevice)
    }

    mutating func seal(_ frame: ControlFrame) throws -> Data { try inner.seal(plaintext: frame.encoded()) }

    mutating func open(_ message: Data) throws -> ControlFrame? {
        let plaintext: Data
        do { plaintext = try inner.open(message: message) } catch {
            let text = "\(error)"
            if text.contains("too short") { throw Failure.badLength }
            if text.contains("not greater") { throw Failure.replayed }
            throw Failure.authentication
        }
        return ControlFrame.decode(plaintext)
    }
}
