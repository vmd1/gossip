import Foundation
import AppKit
import CoreGraphics

/// One decoded `peripheral.input` action (see `schema/message-types.md`).
enum PhoneInputAction: Equatable {
    case move(dx: Double, dy: Double)
    case button(button: Int, down: Bool)
    case click(button: Int, count: Int)
    case scroll(dx: Double, dy: Double)
    case key(name: String, down: Bool?)
    case text(String)

    /// Largest accepted pointer/scroll delta per message, in points; larger values are clamped (a broken sender can't fling the pointer).
    static let maxDelta = 2000.0
    static let maxTextLength = 500

    static func parse(_ payload: JSONValue) -> PhoneInputAction? {
        guard let kind = payload["kind"]?.stringValue else { return nil }
        func num(_ k: String) -> Double? { payload[k]?.numberValue.flatMap { $0.isFinite ? $0 : nil } }
        func clamp(_ v: Double) -> Double { max(-maxDelta, min(maxDelta, v)) }
        func buttonIndex() -> Int { max(0, min(2, Int(num("button") ?? 0))) }
        switch kind {
        case "move":
            guard let dx = num("dx"), let dy = num("dy") else { return nil }
            return .move(dx: clamp(dx), dy: clamp(dy))
        case "button":
            guard case .bool(let down)? = payload["down"] else { return nil }
            return .button(button: buttonIndex(), down: down)
        case "click":
            return .click(button: buttonIndex(), count: max(1, min(3, Int(num("count") ?? 1))))
        case "scroll":
            guard let dx = num("dx"), let dy = num("dy") else { return nil }
            return .scroll(dx: clamp(dx), dy: clamp(dy))
        case "key":
            guard let name = payload["key"]?.stringValue, PhoneInputKeys.code(for: name) != nil else { return nil }
            if case .bool(let down)? = payload["down"] { return .key(name: name, down: down) }
            return .key(name: name, down: nil)
        case "text":
            guard let text = payload["text"]?.stringValue, !text.isEmpty else { return nil }
            return .text(String(text.prefix(maxTextLength)))
        default:
            return nil
        }
    }
}

enum PhoneInputKeys {
    /// Named keys a phone can press, to macOS virtual key codes.
    static func code(for name: String) -> CGKeyCode? {
        switch name {
        case "return": return 36
        case "tab": return 48
        case "space": return 49
        case "backspace": return 51
        case "escape": return 53
        case "delete": return 117
        case "left": return 123
        case "right": return 124
        case "down": return 125
        case "up": return 126
        case "home": return 115
        case "end": return 119
        case "pageup": return 116
        case "pagedown": return 121
        default: return nil
        }
    }
}

/// What actually moves the pointer and types — behind a protocol so the dedupe and decoding are testable.
protocol PhoneInputInjector: AnyObject {
    func perform(_ action: PhoneInputAction)
}

/// Drops duplicate and out-of-order `peripheral.input` messages. Relative pointer moves and key presses are not
/// idempotent, so each message carries a per-session monotonically increasing `seq` and anything at or below the highest
/// one already applied for that `sessionId` is ignored. Bounded: the 16 most recently used sessions are remembered.
struct PhoneInputSequencer {
    private var lastSeq: [String: Int] = [:]
    private var order: [String] = []
    static let maxSessions = 16

    mutating func accept(sessionId: String, seq: Int) -> Bool {
        if let last = lastSeq[sessionId], seq <= last { return false }
        lastSeq[sessionId] = seq
        order.removeAll { $0 == sessionId }
        order.append(sessionId)
        while order.count > Self.maxSessions { lastSeq.removeValue(forKey: order.removeFirst()) }
        return true
    }
}

/// Handles `peripheral.input`: a paired phone acting as this Mac's trackpad and keyboard. Opt-in (`Feature.phoneInput`,
/// off by default, enforced by the router before delivery) and needs Accessibility to post events.
final class PhoneInputManager {
    private let injector: PhoneInputInjector
    private var sequencer = PhoneInputSequencer()
    private let lock = NSLock()

    init(injector: PhoneInputInjector = SystemPhoneInputInjector()) {
        self.injector = injector
    }

    func register(on router: MessageRouter) {
        router.register(prefix: "peripheral.") { [weak self] envelope in self?.handle(envelope) }
    }

    /// The state slot a phone reads to tell the user why its trackpad isn't working. It is deliberately **not** under the
    /// `peripheral.` prefix: with the feature switched off the core drops every `peripheral.` message, and the phone
    /// still has to be able to learn that. Values: `enabled` (the feature switch), `accessibility` (the permission).
    static let statusSlot = "trackpad.status"

    func statusJSON(enabled: Bool, accessibility: Bool) -> String {
        #"{"enabled":\#(enabled),"accessibility":\#(accessibility)}"#
    }

    /// Publishes the status; an unchanged value is a no-op in the core, so this is safe on a timer.
    func publishStatus(on transport: TransportManager) {
        transport.setState(
            slot: Self.statusSlot,
            valueJSON: statusJSON(enabled: FeatureSettings.shared.isEnabled(.phoneInput), accessibility: AXIsProcessTrusted())
        )
    }

    func handle(_ envelope: Envelope) {
        guard envelope.type == "peripheral.input",
              let sessionId = envelope.payload["sessionId"]?.stringValue,
              let seq = envelope.payload["seq"]?.numberValue, seq.isFinite, seq >= 0, seq < Double(Int.max),
              let action = PhoneInputAction.parse(envelope.payload) else { return }
        lock.lock()
        let fresh = sequencer.accept(sessionId: sessionId, seq: Int(seq))
        lock.unlock()
        guard fresh else { return }
        injector.perform(action)
    }
}

/// Posts real `CGEvent`s. Silently does nothing without Accessibility trust.
final class SystemPhoneInputInjector: PhoneInputInjector {
    private var heldButtons: Set<Int> = []
    private let source = CGEventSource(stateID: .hidSystemState)

    func perform(_ action: PhoneInputAction) {
        guard AXIsProcessTrusted() else { return }
        switch action {
        case .move(let dx, let dy):
            moveBy(dx: dx, dy: dy)
        case .button(let button, let down):
            post(button: button, down: down, clickState: 1)
        case .click(let button, let count):
            for i in 1...count { post(button: button, down: true, clickState: i); post(button: button, down: false, clickState: i) }
        case .scroll(let dx, let dy):
            // Positive dy from the phone = fingers moving down = content moves down, matching "natural" scrolling.
            CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0)?
                .post(tap: .cghidEventTap)
        case .key(let name, let down):
            guard let code = PhoneInputKeys.code(for: name) else { return }
            for d in (down.map { [$0] } ?? [true, false]) {
                CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: d)?.post(tap: .cghidEventTap)
            }
        case .text(let text):
            let utf16 = Array(text.utf16)
            for d in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: d)
                event?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    private func moveBy(dx: Double, dy: Double) {
        let current = CGEvent(source: nil)?.location ?? .zero
        var target = CGPoint(x: current.x + dx, y: current.y + dy)
        target = Self.clamp(target)
        let type: CGEventType = heldButtons.contains(0) ? .leftMouseDragged : heldButtons.contains(1) ? .rightMouseDragged : .mouseMoved
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: target, mouseButton: heldButtons.contains(1) ? .right : .left)
        event?.setDoubleValueField(.mouseEventDeltaX, value: dx)
        event?.setDoubleValueField(.mouseEventDeltaY, value: dy)
        event?.post(tap: .cghidEventTap)
    }

    private func post(button: Int, down: Bool, clickState: Int) {
        if down { heldButtons.insert(button) } else { heldButtons.remove(button) }
        let location = CGEvent(source: nil)?.location ?? .zero
        let (type, cgButton): (CGEventType, CGMouseButton) = switch (button, down) {
        case (0, true): (.leftMouseDown, .left)
        case (0, false): (.leftMouseUp, .left)
        case (1, true): (.rightMouseDown, .right)
        case (1, false): (.rightMouseUp, .right)
        case (_, true): (.otherMouseDown, .center)
        case (_, false): (.otherMouseUp, .center)
        }
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: cgButton)
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        event?.post(tap: .cghidEventTap)
    }

    /// Keeps the pointer on the union of the connected displays.
    static func clamp(_ p: CGPoint) -> CGPoint {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success, count > 0 else { return p }
        let bounds = ids.prefix(Int(count)).map { CGDisplayBounds($0) }
        if bounds.contains(where: { $0.contains(p) }) { return p }
        // Not on any display: snap to the nearest point on the closest one.
        var best = p, bestDist = Double.infinity
        for b in bounds {
            let c = CGPoint(x: min(max(p.x, b.minX), b.maxX - 1), y: min(max(p.y, b.minY), b.maxY - 1))
            let d = hypot(c.x - p.x, c.y - p.y)
            if d < bestDist { best = c; bestDist = d }
        }
        return best
    }
}
