import Foundation
import AppKit
import CoreGraphics

/// The real cursor handling: hide it, stop it following the mouse, warp it back. All state changes are
/// idempotent and balanced, and `restore()` is safe to call at any time (quit, sleep, screen lock).
final class SystemCursorController: ControlCursorController {
    private let lock = NSLock()
    private var frozen = false

    func freeze() {
        lock.lock(); defer { lock.unlock() }
        guard !frozen else { return }
        frozen = true
        Self.allowBackgroundCursorHiding()
        CGAssociateMouseAndMouseCursorPosition(0)
        CGDisplayHideCursor(CGMainDisplayID())
    }

    func warp(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        // Warping suppresses local events for a short time by default; we want the mouse to keep working.
        CGEventSource(stateID: .combinedSessionState)?.localEventsSuppressionInterval = 0
    }

    func restore() {
        lock.lock(); defer { lock.unlock() }
        guard frozen else { return }
        frozen = false
        CGAssociateMouseAndMouseCursorPosition(1)
        CGDisplayShowCursor(CGMainDisplayID())
    }

    /// `CGDisplayHideCursor` only works for the frontmost app unless the connection opts in. Gossip is a menu-bar
    /// app and is practically never frontmost, so it sets the same connection property Synergy and Barrier do.
    /// These are private symbols; if they are ever missing the cursor merely stays visible while frozen.
    private static func allowBackgroundCursorHiding() {
        typealias MainConnection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        guard let handle = dlopen(nil, RTLD_NOW),
              let connSym = dlsym(handle, "CGSMainConnectionID"),
              let setSym = dlsym(handle, "CGSSetConnectionProperty") else { return }
        let conn = unsafeBitCast(connSym, to: MainConnection.self)()
        _ = unsafeBitCast(setSym, to: SetProperty.self)(conn, conn, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}
