import Foundation
import CoreGraphics
import GossipCoreKit

/// The Universal Control arrangement as a value type. The geometry (which rectangles touch, snapping, legal drops,
/// resizing, normalising, persistence) is the core's `ControlLayout` (`desktop/core/src/control/layout.rs`), shared with
/// every platform; each call here builds a core layout from this value, so copies stay independent.
///
/// Mac displays are fixed (they come from the OS, keyed by display UUID); device screens are placed by the
/// user. A device's size in this space is its logical pixel size divided by `pixelsPerPoint`, so one Mac
/// point of mouse travel is `pixelsPerPoint` device pixels.
struct ControlLayout: Equatable {
    /// Default scale between device pixels and layout points.
    static let defaultPixelsPerPoint: Double = 1.5
    /// Edges closer than this snap together while dragging.
    /// Typical extra travel Android's pointer acceleration adds to a relative mouse (measured 1.3x to 2x on the
    /// SM-T500, Android 12); used as the router's model gain. See `PointerRouter.pointerGain`.
    static let expectedDeviceAcceleration: Double = 1.5
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

    /// Pixel size to draw a device with before it has ever reported its real one.
    static func defaultPixelSize(for type: DeviceType) -> CGSize {
        CGSize(GossipCoreKit.controlDefaultPixelSize(deviceType: type.rawValue))
    }

    static func deviceSize(pixelWidth: Int, pixelHeight: Int, pixelsPerPoint: Double = defaultPixelsPerPoint) -> CGSize {
        CGSize(GossipCoreKit.controlDeviceSize(pixelWidth: Double(pixelWidth), pixelHeight: Double(pixelHeight), pixelsPerPoint: pixelsPerPoint))
    }

    // MARK: Core bridge

    private var core: GossipCoreKit.ControlLayout {
        GossipCoreKit.ControlLayout(
            localDisplays: macDisplays.map { GossipCoreKit.LocalDisplay(id: $0.key, rect: .init($0.value)) },
            devices: devices.map { GossipCoreKit.DevicePlacement(deviceId: $0.key, rect: .init($0.value.rect)) }
        )
    }

    private mutating func adopt(_ layout: GossipCoreKit.ControlLayout) {
        devices = Dictionary(uniqueKeysWithValues: layout.devices().map { ($0.deviceId, Placement(rect: CGRect($0.rect))) })
    }

    // MARK: Queries

    /// The screen that lies across `edge` of `from` at the layout-space coordinate `along` (x for top/bottom
    /// edges, y for left/right edges). Layout alignment decides the match: the neighbour must touch the edge
    /// and span `along`.
    func neighbor(of from: ScreenID, through edge: ControlEdge, along: Double, excluding: Set<ScreenID> = []) -> ScreenID? {
        core.neighbor(from: from.core, edge: edge.coreEdge, along: along, excluding: excluding.map(\.core)).map(ScreenID.init(core:))
    }

    /// Fraction (0...1) along `edge` of `id` that layout coordinate `along` corresponds to.
    func edgeFraction(of id: ScreenID, edge: ControlEdge, along: Double) -> Double? {
        core.edgeFraction(id: id.core, edge: edge.coreEdge, along: along)
    }

    // MARK: Editing

    /// Replaces the Mac displays (a display was plugged in or rearranged). Devices that no longer fit are returned so the
    /// caller can shelve them.
    mutating func setMacDisplays(_ displays: [String: CGRect]) -> [String] {
        macDisplays = displays
        return normalize()
    }

    /// Resolves a drag: returns the snapped origin for a device of `size` dropped near `proposed`, or nil if
    /// there is no legal spot. `captureDistance`, when positive, lets a drop that is merely *near* an edge attach.
    func resolveDrop(deviceId: String, size: CGSize, proposedOrigin: CGPoint,
                     snapDistance: Double = ControlLayout.snapDistance, captureDistance: Double = 0) -> CGPoint? {
        core.resolveDrop(deviceId: deviceId, size: .init(size), proposedOrigin: .init(proposedOrigin),
                         snapDistance: snapDistance, captureDistance: captureDistance).map(CGPoint.init)
    }

    /// Places (or moves) a device after `resolveDrop`. Returns the final origin, or nil if illegal (unchanged).
    @discardableResult
    mutating func place(deviceId: String, size: CGSize, proposedOrigin: CGPoint,
                        snapDistance: Double = ControlLayout.snapDistance, captureDistance: Double = 0) -> CGPoint? {
        let layout = core
        guard let origin = layout.place(deviceId: deviceId, size: .init(size), proposedOrigin: .init(proposedOrigin),
                                        snapDistance: snapDistance, captureDistance: captureDistance) else { return nil }
        adopt(layout)
        return CGPoint(origin)
    }

    /// Re-sizes a placed device (it reported a new size / rotated), keeping whichever corner stays legal. Returns the ids
    /// removed from the layout.
    mutating func resize(deviceId: String, to size: CGSize) -> [String] {
        let layout = core
        let removed = layout.resize(deviceId: deviceId, size: .init(size))
        adopt(layout)
        return removed
    }

    /// Removes a device (dropped on the shelf) and anything that was only reachable through it.
    mutating func remove(deviceId: String) -> [String] {
        let layout = core
        let removed = layout.remove(deviceId: deviceId)
        adopt(layout)
        return removed
    }

    /// Drops devices that overlap something or are not connected to a Mac display. Returns the ids dropped.
    @discardableResult
    mutating func normalize() -> [String] {
        let layout = core
        let dropped = layout.setLocalDisplays(displays: macDisplays.map { GossipCoreKit.LocalDisplay(id: $0.key, rect: .init($0.value)) })
        adopt(layout)
        return dropped
    }

    // MARK: Persistence

    func encodedDevices() throws -> Data { Data(core.encodeDevices().utf8) }

    static func decodeDevices(_ data: Data) -> [String: Placement]? {
        guard let placements = GossipCoreKit.controlDecodeDevices(json: String(decoding: data, as: UTF8.self)) else { return nil }
        return Dictionary(uniqueKeysWithValues: placements.map { ($0.deviceId, Placement(rect: CGRect($0.rect))) })
    }
}

extension ControlLayout.ScreenID {
    fileprivate var core: GossipCoreKit.ScreenId {
        switch self { case .mac(let id): return .local(id: id); case .device(let id): return .device(id: id) }
    }
    fileprivate init(core: GossipCoreKit.ScreenId) {
        switch core { case .local(let id): self = .mac(id); case .device(let id): self = .device(id) }
    }
}

extension ControlEdge {
    fileprivate var coreEdge: GossipCoreKit.ControlEdge {
        switch self { case .left: return .left; case .right: return .right; case .top: return .top; case .bottom: return .bottom }
    }
}

extension GossipCoreKit.Rect { fileprivate init(_ r: CGRect) { self.init(x: r.minX, y: r.minY, width: r.width, height: r.height) } }
extension GossipCoreKit.Size { fileprivate init(_ s: CGSize) { self.init(width: s.width, height: s.height) } }
extension GossipCoreKit.Point { fileprivate init(_ p: CGPoint) { self.init(x: p.x, y: p.y) } }
extension CGRect { fileprivate init(_ r: GossipCoreKit.Rect) { self.init(x: r.x, y: r.y, width: r.width, height: r.height) } }
extension CGSize { fileprivate init(_ s: GossipCoreKit.Size) { self.init(width: s.width, height: s.height) } }
extension CGPoint { fileprivate init(_ p: GossipCoreKit.Point) { self.init(x: p.x, y: p.y) } }
