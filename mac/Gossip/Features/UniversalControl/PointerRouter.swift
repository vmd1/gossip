import Foundation
import CoreGraphics
import GossipCoreKit

/// The crossing engine: decides where the pointer is (the Mac, or one device) and turns mouse deltas into actions. The
/// state machine is the core's `PointerRouter` (`desktop/core/src/control/pointer.rs`), shared with every platform; this
/// wrapper keeps the app-facing types, and the manager performs the actions, so it stays testable with fake targets.
///
/// - LOCAL: the Mac cursor moves normally. Pushing against a Mac display edge that is adjacent to a ready device, for
///   `pushThreshold` points of accumulated outward travel, enters that device.
/// - REMOTE(device): deltas are integrated inside that device's rectangle (layout space). Reaching an edge adjacent to
///   another ready device hands over to it; reaching one adjacent to a Mac display returns to the Mac, at the position the
///   layout alignment gives. Edges with nothing beyond them are walls.
struct PointerRouter {
    enum State: Equatable {
        case local
        case remote(deviceId: String, position: CGPoint)

        var remoteDeviceId: String? { if case .remote(let id, _) = self { return id } else { return nil } }
    }

    enum Action: Equatable {
        /// Tell `deviceId` the cursor enters through `edge`, `fraction` (0...1) along it.
        case enter(deviceId: String, edge: ControlEdge, fraction: Double)
        case leave(deviceId: String)
        /// Relative motion in layout points (the manager converts to device pixels).
        case move(deviceId: String, dx: Double, dy: Double)
        /// Put the real Mac cursor here (global Mac coordinates, y down).
        case warpMacCursor(CGPoint)
    }

    private let core: GossipCoreKit.PointerRouter
    private(set) var layout: ControlLayout
    /// Devices with a live, ready session; anything else is a wall.
    var readyDevices: Set<String> = [] { didSet { core.setReadyDevices(devices: Array(readyDevices)) } }
    /// The device moves its cursor `pointerGain` times further than the deltas we send (Android applies pointer
    /// acceleration to a relative mouse); the model integrates with this gain so the edge a user sees the cursor hit is
    /// the edge the router crosses. The *sent* delta is unchanged.
    var pointerGain: Double = 1 { didSet { core.setPointerGain(gain: pointerGain) } }

    var state: State {
        switch core.state() {
        case .local: return .local
        case .remote(let id, let position): return .remote(deviceId: id, position: CGPoint(x: position.x, y: position.y))
        }
    }

    init(layout: ControlLayout, pushThreshold: Double = 36) {
        self.layout = layout
        core = GossipCoreKit.PointerRouter(layout: layout.coreLayout, pushThreshold: pushThreshold)
    }

    mutating func setLayout(_ newLayout: ControlLayout) -> [Action] {
        layout = newLayout
        return core.setLayout(layout: newLayout.coreLayout).map(Self.action)
    }

    mutating func deviceBecameUnavailable(_ deviceId: String) -> [Action] {
        readyDevices.remove(deviceId)
        return core.deviceBecameUnavailable(deviceId: deviceId).map(Self.action)
    }

    /// A Mac mouse movement while LOCAL. `location` is the cursor position after the OS applied the move.
    mutating func macMoved(delta: CGPoint, location: CGPoint) -> [Action] {
        core.localMoved(delta: .init(x: delta.x, y: delta.y), location: .init(x: location.x, y: location.y)).map(Self.action)
    }

    /// A Mac mouse movement while REMOTE (deltas only; the real cursor is frozen).
    mutating func remoteMoved(delta: CGPoint) -> [Action] {
        core.remoteMoved(delta: .init(x: delta.x, y: delta.y)).map(Self.action)
    }

    /// Escape hatch / session loss: go back to the Mac now. `nearestTo` is a Mac point hint; without one the pointer is
    /// placed where the device was attached (or the main display's centre).
    mutating func forceReturn(nearestTo hint: CGPoint?, notifyDevice: Bool = true) -> [Action] {
        core.forceReturn(hint: hint.map { .init(x: $0.x, y: $0.y) }, notifyDevice: notifyDevice).map(Self.action)
    }

    /// Whether the modelled cursor is within `margin` points of an edge of the device it is on that leads to another
    /// screen: the only place an inaccurate model matters.
    func isNearExitEdge(margin: Double) -> Bool { core.isNearExitEdge(margin: margin) }

    /// The device told us where its real cursor is: move the model by `offset` (real minus modelled at that moment),
    /// staying inside the device. Never triggers a hand-over by itself; the next movement does.
    mutating func shiftRemotePosition(by offset: CGVector) { core.shiftRemotePosition(dx: offset.dx, dy: offset.dy) }

    private static func action(_ a: GossipCoreKit.PointerAction) -> Action {
        switch a {
        case .enter(let id, let edge, let fraction): return .enter(deviceId: id, edge: ControlEdge(coreEdge: edge), fraction: fraction)
        case .leave(let id): return .leave(deviceId: id)
        case .move(let id, let dx, let dy): return .move(deviceId: id, dx: dx, dy: dy)
        case .warpCursor(let point): return .warpMacCursor(CGPoint(x: point.x, y: point.y))
        }
    }
}

extension ControlEdge {
    fileprivate init(coreEdge: GossipCoreKit.ControlEdge) {
        switch coreEdge { case .left: self = .left; case .right: self = .right; case .top: self = .top; case .bottom: self = .bottom }
    }
}
