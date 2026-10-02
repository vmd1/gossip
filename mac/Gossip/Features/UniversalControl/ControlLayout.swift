import Foundation
import CoreGraphics

/// Pure geometry of the Universal Control arrangement: which rectangles exist, which touch, how the
/// pointer maps from one to the next. No AppKit, no I/O, no platform assumptions beyond "a screen is a
/// rectangle in a shared, y-down, point-based space" — a Windows or Linux source would feed it the same way.
///
/// Mac displays are fixed (they come from the OS, keyed by display UUID); device screens are placed by the
/// user. A device's size in this space is its logical pixel size divided by `pixelsPerPoint`, so one Mac
/// point of mouse travel is `pixelsPerPoint` device pixels.
struct ControlLayout: Equatable {
    /// Default scale between device pixels and layout points.
    static let defaultPixelsPerPoint: Double = 1.5
    /// Edges closer than this snap together while dragging.
    static let snapDistance: Double = 24
    /// Two edges count as touching when they are at most this far apart.
    static let touchTolerance: Double = 1

    enum ScreenID: Hashable, Codable, Comparable {
        case mac(String)      // display UUID
        case device(String)   // Gossip deviceId

        var deviceId: String? { if case .device(let id) = self { return id } else { return nil } }
        var isMac: Bool { if case .mac = self { return true } else { return false } }

        static func < (a: ScreenID, b: ScreenID) -> Bool { a.sortKey < b.sortKey }
        private var sortKey: String {
            switch self {
            case .mac(let s): return "0" + s
            case .device(let s): return "1" + s
            }
        }
    }

    struct Placement: Codable, Equatable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
        init(rect: CGRect) { x = rect.minX; y = rect.minY; width = rect.width; height = rect.height }
    }

    /// Fixed rectangles of the Mac's displays.
    private(set) var macDisplays: [String: CGRect]
    /// User-placed device screens.
    private(set) var devices: [String: Placement]

    init(macDisplays: [String: CGRect] = [:], devices: [String: Placement] = [:]) {
        self.macDisplays = macDisplays
        self.devices = devices
    }

    // MARK: Queries

    var screens: [(id: ScreenID, rect: CGRect)] {
        macDisplays.map { (ScreenID.mac($0.key), $0.value) } + devices.map { (ScreenID.device($0.key), $0.value.rect) }
    }

    func rect(of id: ScreenID) -> CGRect? {
        switch id {
        case .mac(let u): return macDisplays[u]
        case .device(let d): return devices[d]?.rect
        }
    }

    func isPlaced(_ deviceId: String) -> Bool { devices[deviceId] != nil }

    static func deviceSize(pixelWidth: Int, pixelHeight: Int, pixelsPerPoint: Double = defaultPixelsPerPoint) -> CGSize {
        CGSize(width: Double(pixelWidth) / pixelsPerPoint, height: Double(pixelHeight) / pixelsPerPoint)
    }

    /// The screen that lies across `edge` of `from` at the layout-space coordinate `along` (x for top/bottom
    /// edges, y for left/right edges). Layout alignment decides the match: the neighbour must touch the edge
    /// and span `along`.
    func neighbor(of from: ScreenID, through edge: ControlEdge, along: Double, excluding: Set<ScreenID> = []) -> ScreenID? {
        guard let r = rect(of: from) else { return nil }
        let tol = Self.touchTolerance
        for (id, other) in screens where id != from && !excluding.contains(id) {
            let touches: Bool
            let spans: Bool
            switch edge {
            case .right:  touches = abs(other.minX - r.maxX) <= tol; spans = along >= other.minY && along <= other.maxY
            case .left:   touches = abs(other.maxX - r.minX) <= tol; spans = along >= other.minY && along <= other.maxY
            case .bottom: touches = abs(other.minY - r.maxY) <= tol; spans = along >= other.minX && along <= other.maxX
            case .top:    touches = abs(other.maxY - r.minY) <= tol; spans = along >= other.minX && along <= other.maxX
            }
            if touches && spans { return id }
        }
        return nil
    }

    /// Fraction (0...1) along `edge` of `id` that layout coordinate `along` corresponds to.
    func edgeFraction(of id: ScreenID, edge: ControlEdge, along: Double) -> Double? {
        guard let r = rect(of: id) else { return nil }
        let (lo, len) = (edge == .left || edge == .right) ? (r.minY, r.height) : (r.minX, r.width)
        guard len > 0 else { return nil }
        return min(1, max(0, (along - lo) / len))
    }

    // MARK: Editing

    /// Replaces the Mac displays (a display was plugged in or rearranged). Devices that no longer overlap-free
    /// or touch anything are returned so the caller can shelve them.
    mutating func setMacDisplays(_ displays: [String: CGRect]) -> [String] {
        macDisplays = displays
        return normalize()
    }

    /// Resolves a drag: returns the snapped origin for a device of `size` dropped near `proposed`, or nil if
    /// there is no legal spot (overlap, or not touching anything). `deviceId`'s own old placement is ignored.
    func resolveDrop(deviceId: String, size: CGSize, proposedOrigin: CGPoint) -> CGPoint? {
        let others = screens.filter { $0.id != .device(deviceId) }.map { $0.rect }
        guard !others.isEmpty else { return nil }
        var rect = CGRect(origin: proposedOrigin, size: size)

        // Snap each axis independently to the nearest candidate edge alignment (touching, or flush-aligned
        // along the shared edge).
        var bestDX: Double? = nil, bestDY: Double? = nil
        func consider(_ delta: Double, into best: inout Double?) {
            if abs(delta) <= Self.snapDistance, best == nil || abs(delta) < abs(best!) { best = delta }
        }
        for o in others {
            // Horizontal touching: my left to their right, my right to their left (only if rows overlap-ish).
            consider(o.maxX - rect.minX, into: &bestDX)
            consider(o.minX - rect.maxX, into: &bestDX)
            // Vertical touching.
            consider(o.maxY - rect.minY, into: &bestDY)
            consider(o.minY - rect.maxY, into: &bestDY)
            // Flush alignment along a shared edge.
            consider(o.minX - rect.minX, into: &bestDX)
            consider(o.maxX - rect.maxX, into: &bestDX)
            consider(o.minY - rect.minY, into: &bestDY)
            consider(o.maxY - rect.maxY, into: &bestDY)
        }
        // Try the combinations of snapped / unsnapped axes and keep the first legal, closest one.
        var candidates: [CGPoint] = []
        let origin = rect.origin
        if let dx = bestDX, let dy = bestDY { candidates.append(CGPoint(x: origin.x + dx, y: origin.y + dy)) }
        if let dx = bestDX { candidates.append(CGPoint(x: origin.x + dx, y: origin.y)) }
        if let dy = bestDY { candidates.append(CGPoint(x: origin.x, y: origin.y + dy)) }
        candidates.append(origin)
        for c in candidates {
            rect.origin = c
            if isLegal(rect, against: others) { return c }
        }
        return nil
    }

    /// No overlap with any of `others`, and shares a positive-length edge segment with at least one.
    func isLegal(_ rect: CGRect, against others: [CGRect]) -> Bool {
        var touching = false
        for o in others {
            let inter = rect.intersection(o)
            if !inter.isNull && inter.width > Self.touchTolerance && inter.height > Self.touchTolerance { return false }
            if Self.sharedEdgeLength(rect, o) > Self.touchTolerance { touching = true }
        }
        return touching
    }

    static func sharedEdgeLength(_ a: CGRect, _ b: CGRect) -> Double {
        let tol = touchTolerance
        func overlap(_ a0: Double, _ a1: Double, _ b0: Double, _ b1: Double) -> Double { max(0, min(a1, b1) - max(a0, b0)) }
        if abs(a.maxX - b.minX) <= tol || abs(b.maxX - a.minX) <= tol { return overlap(a.minY, a.maxY, b.minY, b.maxY) }
        if abs(a.maxY - b.minY) <= tol || abs(b.maxY - a.minY) <= tol { return overlap(a.minX, a.maxX, b.minX, b.maxX) }
        return 0
    }

    /// Places (or moves) a device after `resolveDrop`. Returns the final origin, or nil if illegal (unchanged).
    @discardableResult
    mutating func place(deviceId: String, size: CGSize, proposedOrigin: CGPoint) -> CGPoint? {
        guard let origin = resolveDrop(deviceId: deviceId, size: size, proposedOrigin: proposedOrigin) else { return nil }
        devices[deviceId] = Placement(rect: CGRect(origin: origin, size: size))
        return origin
    }

    /// Re-sizes a placed device (it reported a new size / rotated), keeping its top-left. If that makes the
    /// layout illegal the device is shelved. Returns the ids removed from the layout.
    mutating func resize(deviceId: String, to size: CGSize) -> [String] {
        guard var p = devices[deviceId] else { return [] }
        p.width = size.width; p.height = size.height
        devices[deviceId] = p
        return normalize()
    }

    /// Removes a device (dropped on the shelf) and anything that was only reachable through it.
    mutating func remove(deviceId: String) -> [String] {
        guard devices.removeValue(forKey: deviceId) != nil else { return [] }
        return [deviceId] + normalize()
    }

    /// Drops devices that overlap something or are not connected (through touching edges) to a Mac display.
    /// Returns the ids dropped, in no particular order.
    @discardableResult
    mutating func normalize() -> [String] {
        var dropped: [String] = []
        // Overlaps: drop the device(s) that overlap Mac displays or earlier-kept devices.
        var kept: [(ScreenID, CGRect)] = macDisplays.map { (.mac($0.key), $0.value) }
        for (id, p) in devices.sorted(by: { $0.key < $1.key }) {
            let overlaps = kept.contains { _, r in
                let i = p.rect.intersection(r)
                return !i.isNull && i.width > Self.touchTolerance && i.height > Self.touchTolerance
            }
            if overlaps { devices[id] = nil; dropped.append(id) } else { kept.append((.device(id), p.rect)) }
        }
        // Connectivity: breadth-first from the Mac displays across shared edges.
        var reached = Set(macDisplays.keys.map { ScreenID.mac($0) })
        var frontier = Array(reached)
        while let cur = frontier.popLast() {
            guard let cr = rect(of: cur) else { continue }
            for (id, p) in devices where !reached.contains(.device(id)) {
                if Self.sharedEdgeLength(cr, p.rect) > Self.touchTolerance {
                    reached.insert(.device(id)); frontier.append(.device(id))
                }
            }
        }
        for id in devices.keys where !reached.contains(.device(id)) { devices[id] = nil; dropped.append(id) }
        return dropped
    }

    // MARK: Persistence

    private struct Stored: Codable { var version = 1; var devices: [String: Placement] }

    func encodedDevices() throws -> Data {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(Stored(devices: devices))
    }

    static func decodeDevices(_ data: Data) -> [String: Placement]? {
        (try? JSONDecoder().decode(Stored.self, from: data))?.devices
    }
}
