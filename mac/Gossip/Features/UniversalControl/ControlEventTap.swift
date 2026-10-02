import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

/// Captures the Mac's mouse and keyboard with a default (active) `CGEventTap` so events can be swallowed
/// while the pointer is on another device. Needs two grants, both tied to the app's code signature (see
/// `scripts/create-signing-cert.sh`): Accessibility (to modify/swallow events) and Input Monitoring (to
/// listen). The tap lives on its own thread so a busy main thread can't make macOS disable it, and it is
/// re-enabled if macOS disables it anyway. Secure input (password fields) hides keystrokes from any tap — a
/// macOS rule, nothing to work around.
final class ControlEventTap {
    /// Called on the tap thread for every event of interest; must answer immediately.
    var handler: ((ControlInputEvent) -> ControlDisposition)?

    private var tap: CFMachPort?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private let lock = NSLock()

    // MARK: Permissions

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }
    static var inputMonitoringGranted: Bool { CGPreflightListenEventAccess() }

    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    static func requestInputMonitoring() { _ = CGRequestListenEventAccess() }

    static func openSystemSettings(pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
    static func openAccessibilitySettings() { openSystemSettings(pane: "Privacy_Accessibility") }
    static func openInputMonitoringSettings() { openSystemSettings(pane: "Privacy_ListenEvent") }

    // MARK: Lifecycle

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return tap != nil }

    @discardableResult
    func start() -> Bool {
        lock.lock()
        guard tap == nil else { lock.unlock(); return true }
        guard Self.accessibilityGranted else { lock.unlock(); return false }

        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
            .scrollWheel, .keyDown, .keyUp, .flagsChanged,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            return Unmanaged<ControlEventTap>.fromOpaque(refcon).takeUnretainedValue().receive(type: type, event: event)
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { lock.unlock(); return false }
        tap = port

        let ready = DispatchSemaphore(value: 0)
        let t = Thread { [weak self] in
            guard let self else { return }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            self.lock.lock(); self.runLoop = CFRunLoopGetCurrent(); self.lock.unlock()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            ready.signal()
            CFRunLoopRun()
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        t.name = "dev.vmd1.gossip.control.eventtap"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        // Must not wait while holding `lock`: the tap thread takes it to publish its run loop before signalling.
        lock.unlock()
        ready.wait()
        return true
    }

    func stop() {
        lock.lock()
        let port = tap, rl = runLoop
        tap = nil; runLoop = nil; thread = nil
        lock.unlock()
        if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        if let rl { CFRunLoopStop(rl) }
    }

    // MARK: Event conversion

    private func receive(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            lock.lock(); let port = tap; lock.unlock()
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        default:
            break
        }
        // Events we post ourselves (none today) and synthetic test events carry this marker: never capture them.
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker { return Unmanaged.passUnretained(event) }
        guard let converted = Self.convert(type: type, event: event), let handler else { return Unmanaged.passUnretained(event) }
        return handler(converted) == .swallow ? nil : Unmanaged.passUnretained(event)
    }

    /// Set on events a script posts to drive the tap in the E2E CLI is *not* skipped (it must exercise the tap);
    /// this marker is reserved for events Gossip itself synthesises.
    static let syntheticMarker: Int64 = 0x474F5353

    static func convert(type: CGEventType, event: CGEvent) -> ControlInputEvent? {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let delta = CGPoint(x: CGFloat(event.getIntegerValueField(.mouseEventDeltaX)), y: CGFloat(event.getIntegerValueField(.mouseEventDeltaY)))
            return .mouseMoved(delta: delta, location: event.location)
        case .leftMouseDown, .leftMouseUp:
            return .button(index: 0, down: type == .leftMouseDown, location: event.location)
        case .rightMouseDown, .rightMouseUp:
            return .button(index: 1, down: type == .rightMouseDown, location: event.location)
        case .otherMouseDown, .otherMouseUp:
            let n = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            // macOS numbers: 2 = middle, 3 = back, 4 = forward.
            return .button(index: n, down: type == .otherMouseDown, location: event.location)
        case .scrollWheel:
            let dy = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
            let dx = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
            return .scroll(dx: Int(dx) * 12, dy: Int(dy) * 12)
        case .keyDown, .keyUp:
            let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            var length = 0
            var buffer = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &buffer)
            let characters = length > 0 ? String(utf16CodeUnits: buffer, count: length) : nil
            return .key(
                keyCode: code, down: type == .keyDown,
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                characters: characters, flags: modifierFlags(event.flags)
            )
        case .flagsChanged:
            let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            guard let down = modifierIsDown(keyCode: code, rawFlags: event.flags.rawValue) else { return nil }
            return .modifier(keyCode: code, down: down)
        default:
            return nil
        }
    }

    static func modifierFlags(_ f: CGEventFlags) -> ControlModifierFlags {
        var m: ControlModifierFlags = []
        if f.contains(.maskShift) { m.insert(.shift) }
        if f.contains(.maskControl) { m.insert(.control) }
        if f.contains(.maskAlternate) { m.insert(.option) }
        if f.contains(.maskCommand) { m.insert(.command) }
        return m
    }

    /// Whether the modifier key `keyCode` is down according to the device-dependent bits (`NX_DEVICE*KEYMASK`)
    /// in the event flags. Caps Lock has no separate press/release, so it reports a tap as "down".
    static func modifierIsDown(keyCode: UInt16, rawFlags: UInt64) -> Bool? {
        let mask: UInt64
        switch keyCode {
        case 59: mask = 0x0000_0001   // left control
        case 56: mask = 0x0000_0002   // left shift
        case 60: mask = 0x0000_0004   // right shift
        case 55: mask = 0x0000_0008   // left command
        case 54: mask = 0x0000_0010   // right command
        case 58: mask = 0x0000_0020   // left option
        case 61: mask = 0x0000_0040   // right option
        case 62: mask = 0x0000_2000   // right control
        case 57: return true          // caps lock
        default: return nil
        }
        return rawFlags & mask != 0
    }
}
