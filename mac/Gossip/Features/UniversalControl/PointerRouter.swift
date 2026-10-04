import Foundation
import CoreGraphics

/// The crossing engine: decides where the pointer is (the Mac, or one device) and turns mouse deltas into
/// actions. Pure state machine over `ControlLayout` — the manager performs the actions, so this is testable
/// with fake targets.
///
/// - LOCAL: the Mac cursor moves normally. Pushing against a Mac display edge that is adjacent to a ready
///   device, for `pushThreshold` points of accumulated outward travel, enters that device.
/// - REMOTE(device): deltas are integrated inside that device's rectangle (layout space). Reaching an edge
///   adjacent to another ready device hands over to it; reaching one adjacent to a Mac display returns to
///   the Mac, at the position the layout alignment gives. Edges with nothing beyond them are walls.
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

    private(set) var layout: ControlLayout
    private(set) var state: State = .local
    /// Devices with a live, ready session; anything else is a wall.
    var readyDevices: Set<String> = []
    var pushThreshold: Double
    /// The device moves its cursor `pointerGain` times further than the deltas we send (Android applies pointer
    /// acceleration to a relative mouse; measured on the SM-T500 at 1.3x to 2x). The model integrates with this
    /// gain so the edge a user sees the cursor hit is the edge the router crosses; the *sent* delta is unchanged.
    var pointerGain: Double = 1
    /// How far inside the destination the pointer is placed after crossing, so it doesn't instantly re-cross.
    var insetPoints: Double = 2

    private var pushAccumulator: Double = 0
    private var pushKey: PushKey?
    private struct PushKey: Equatable { var display: String; var edge: ControlEdge; var deviceId: String }

    init(layout: ControlLayout, pushThreshold: Double = 36) {
        self.layout = layout
        self.pushThreshold = pushThreshold
    }

    mutating func setLayout(_ newLayout: ControlLayout) -> [Action] {
        layout = newLayout
        resetPush()
        // The device we were controlling may have been shelved.
        if case .remote(let id, _) = state, !layout.isPlaced(id) { return forceReturn(nearestTo: nil) }
        return []
    }

    mutating func deviceBecameUnavailable(_ deviceId: String) -> [Action] {
        readyDevices.remove(deviceId)
        if state.remoteDeviceId == deviceId { return forceReturn(nearestTo: nil, notifyDevice: false) }
        return []
    }

    private mutating func resetPush() { pushAccumulator = 0; pushKey = nil }

    // MARK: LOCAL

    /// A Mac mouse movement while LOCAL. `location` is the cursor position after the OS applied the move.
    mutating func macMoved(delta: CGPoint, location: CGPoint) -> [Action] {
        guard case .local = state else { return [] }
        guard let (uuid, rect) = nearestMacDisplay(to: location) else { return [] }
        let eps = 1.5
        // Which edge is the cursor being pushed against?
        var edge: ControlEdge?
        let candidates: [(ControlEdge, Bool, Double)] = [
            (.left, location.x <= rect.minX + eps && delta.x < 0, -delta.x),
            (.right, location.x >= rect.maxX - eps && delta.x > 0, delta.x),
            (.top, location.y <= rect.minY + eps && delta.y < 0, -delta.y),
            (.bottom, location.y >= rect.maxY - eps && delta.y > 0, delta.y),
        ]
        var push = 0.0
        for (e, pressed, amount) in candidates where pressed && amount > push { edge = e; push = amount }
        guard let edge else { resetPush(); return [] }

        let along = (edge == .left || edge == .right) ? location.y : location.x
        guard case .device(let deviceId)? = layout.neighbor(of: .mac(uuid), through: edge, along: along),
              readyDevices.contains(deviceId) else { resetPush(); return [] }

        let key = PushKey(display: uuid, edge: edge, deviceId: deviceId)
        if pushKey != key { pushKey = key; pushAccumulator = 0 }
        pushAccumulator += push
        guard pushAccumulator >= pushThreshold else { return [] }
        resetPush()
        return enterDevice(deviceId, from: edge, alongLayout: along)
    }

    // MARK: REMOTE

    /// A Mac mouse movement while REMOTE (deltas only; the real cursor is frozen).
    mutating func remoteMoved(delta: CGPoint) -> [Action] {
        guard case .remote(let id, let pos) = state, let rect = layout.rect(of: .device(id)) else { return [] }
        var actions: [Action] = []
        let target = CGPoint(x: pos.x + delta.x * pointerGain, y: pos.y + delta.y * pointerGain)
        // Always send the full delta: the device clamps at its own edges, which re-synchronises its cursor
        // with ours whenever the pointer is pushed into a wall.
        if delta.x != 0 || delta.y != 0 { actions.append(.move(deviceId: id, dx: delta.x, dy: delta.y)) }

        // Which edge (if any) did we cross? Prefer the axis that overshoots more.
        let overLeft = rect.minX - target.x, overRight = target.x - rect.maxX
        let overTop = rect.minY - target.y, overBottom = target.y - rect.maxY
        let overs: [(ControlEdge, Double)] = [(.left, overLeft), (.right, overRight), (.top, overTop), (.bottom, overBottom)]
        let crossed = overs.filter { $0.1 > 0 }.max { $0.1 < $1.1 }
        let clamped = CGPoint(x: min(max(target.x, rect.minX), rect.maxX), y: min(max(target.y, rect.minY), rect.maxY))

        if let (edge, _) = crossed {
            let along = (edge == .left || edge == .right) ? clamped.y : clamped.x
            if let next = layout.neighbor(of: .device(id), through: edge, along: along) {
                switch next {
                case .device(let other) where readyDevices.contains(other):
                    actions.append(.leave(deviceId: id))
                    actions.append(contentsOf: enterDevice(other, from: edge, alongLayout: along))
                    return actions
                case .mac(let uuid):
                    if let point = macPoint(display: uuid, crossing: edge, alongLayout: along) {
                        actions.append(.leave(deviceId: id))
                        actions.append(.warpMacCursor(point))
                        state = .local
                        resetPush()
                        return actions
                    }
                default:
                    break
                }
            }
        }
        state = .remote(deviceId: id, position: clamped)
        return actions
    }

    /// Escape hatch / session loss: go back to the Mac now. `nearestTo` is a Mac point hint; without one the
    /// pointer is placed where the device was attached (or the main display's centre).
    mutating func forceReturn(nearestTo hint: CGPoint?, notifyDevice: Bool = true) -> [Action] {
        guard case .remote(let id, let pos) = state else { return [] }
        var actions: [Action] = []
        if notifyDevice { actions.append(.leave(deviceId: id)) }
        let point = hint ?? returnPoint(from: id, position: pos)
        if let point { actions.append(.warpMacCursor(point)) }
        state = .local
        resetPush()
        return actions
    }

    // MARK: Closed-loop correction

    /// Whether the modelled cursor is within `margin` points of an edge of the device it is on that leads to
    /// another screen — the only place an inaccurate model matters (that is where it decides to hand over).
    func isNearExitEdge(margin: Double) -> Bool {
        guard case .remote(let id, let pos) = state, let r = layout.rect(of: .device(id)) else { return false }
        let m = min(margin, r.width / 2, r.height / 2)
        let candidates: [(ControlEdge, Double, Double)] = [
            (.left, pos.x - r.minX, pos.y), (.right, r.maxX - pos.x, pos.y),
            (.top, pos.y - r.minY, pos.x), (.bottom, r.maxY - pos.y, pos.x),
        ]
        for (edge, distance, along) in candidates where distance <= m {
            if layout.neighbor(of: .device(id), through: edge, along: along) != nil { return true }
        }
        return false
    }

    /// The device told us where its real cursor is: move the model by `offset` (real minus modelled at that
    /// moment), staying inside the device. Never triggers a hand-over by itself; the next movement does.
    mutating func shiftRemotePosition(by offset: CGVector) {
        guard case .remote(let id, let pos) = state, let r = layout.rect(of: .device(id)) else { return }
        state = .remote(deviceId: id, position: CGPoint(x: min(max(pos.x + offset.dx, r.minX), r.maxX),
                                                        y: min(max(pos.y + offset.dy, r.minY), r.maxY)))
        resetPush()
    }

    // MARK: Helpers

    private mutating func enterDevice(_ deviceId: String, from exitEdge: ControlEdge, alongLayout along: Double) -> [Action] {
        guard let rect = layout.rect(of: .device(deviceId)) else { return [] }
        let entryEdge = exitEdge.opposite
        let fraction = layout.edgeFraction(of: .device(deviceId), edge: entryEdge, along: along) ?? 0.5
        let inset = insetPoints
        let pos: CGPoint
        switch entryEdge {
        case .left: pos = CGPoint(x: rect.minX + inset, y: min(max(along, rect.minY), rect.maxY))
        case .right: pos = CGPoint(x: rect.maxX - inset, y: min(max(along, rect.minY), rect.maxY))
        case .top: pos = CGPoint(x: min(max(along, rect.minX), rect.maxX), y: rect.minY + inset)
        case .bottom: pos = CGPoint(x: min(max(along, rect.minX), rect.maxX), y: rect.maxY - inset)
        }
        state = .remote(deviceId: deviceId, position: pos)
        return [.enter(deviceId: deviceId, edge: entryEdge, fraction: fraction)]
    }

    private func nearestMacDisplay(to p: CGPoint) -> (String, CGRect)? {
        var best: (String, CGRect, Double)?
        for (id, r) in layout.macDisplays {
            let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
            let d = Double(dx * dx + dy * dy)
            if best == nil || d < best!.2 { best = (id, r, d) }
        }
        return best.map { ($0.0, $0.1) }
    }

    /// Where on Mac display `uuid` the pointer lands after leaving across `edge` of a device at layout `along`.
    private func macPoint(display uuid: String, crossing edge: ControlEdge, alongLayout along: Double) -> CGPoint? {
        guard let r = layout.macDisplays[uuid] else { return nil }
        let inset = insetPoints
        let y = min(max(along, r.minY + 1), r.maxY - 1), x = min(max(along, r.minX + 1), r.maxX - 1)
        switch edge {
        case .left: return CGPoint(x: r.maxX - inset, y: y)    // left out of the device: land on the Mac's right edge
        case .right: return CGPoint(x: r.minX + inset, y: y)
        case .top: return CGPoint(x: x, y: r.maxY - inset)
        case .bottom: return CGPoint(x: x, y: r.minY + inset)
        }
    }

    private func returnPoint(from deviceId: String, position: CGPoint) -> CGPoint? {
        guard let rect = layout.rect(of: .device(deviceId)) else { return mainDisplayCenter() }
        // The Mac display closest to where the device sits.
        var best: (CGRect, Double)?
        for (_, r) in layout.macDisplays {
            let dx = max(r.minX - rect.midX, 0, rect.midX - r.maxX), dy = max(r.minY - rect.midY, 0, rect.midY - r.maxY)
            let d = Double(dx * dx + dy * dy)
            if best == nil || d < best!.1 { best = (r, d) }
        }
        guard let r = best?.0 else { return nil }
        return CGPoint(x: min(max(rect.midX, r.minX + 2), r.maxX - 2), y: min(max(rect.midY, r.minY + 2), r.maxY - 2))
    }

    private func mainDisplayCenter() -> CGPoint? {
        layout.macDisplays.values.first.map { CGPoint(x: $0.midX, y: $0.midY) }
    }
}
