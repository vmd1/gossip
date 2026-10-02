import SwiftUI
import AppKit

/// "Arrange Devices": a scaled canvas with the Mac's displays (fixed) and the devices the user has placed
/// around them. Drag a device to move it (it snaps to nearby edges; overlaps and floating spots are
/// rejected and it springs back). Drag it onto the shelf along the bottom to take it out of the layout, and
/// back out to place it. Newly paired devices start on the shelf.
struct ControlLayoutView: View {
    @ObservedObject var manager: UniversalControlManager
    @ObservedObject var trustedDevices: TrustedDevicesStore
    @ObservedObject var transport: TransportManager
    @ObservedObject var battery: BatterySyncManager

    private struct Drag: Equatable {
        var deviceId: String
        var size: CGSize          // in screen points (scaled)
        var topLeft: CGPoint      // in the "root" coordinate space
    }
    @State private var drag: Drag?
    @State private var shelfFrame: CGRect = .zero
    @State private var canvasFrame: CGRect = .zero

    private var androidDevices: [TrustedDevice] { trustedDevices.devices.filter { $0.deviceType != .mac } }
    private var shelved: [TrustedDevice] { androidDevices.filter { !manager.layout.isPlaced($0.deviceId) } }

    var body: some View {
        VStack(spacing: 0) {
            canvas
            Divider()
            shelf
        }
        .coordinateSpace(name: "root")
        .overlay(alignment: .topLeading) { ghost }
        .frame(minWidth: 560, minHeight: 420)
    }

    // MARK: Canvas

    private struct Transform {
        var scale: CGFloat
        var origin: CGPoint   // layout point drawn at the canvas's top-left
        func toCanvas(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - origin.x) * scale, y: (p.y - origin.y) * scale) }
        func toLayout(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / scale + origin.x, y: p.y / scale + origin.y) }
    }

    /// Fits everything with room around it to drop devices into.
    private func transform(in size: CGSize) -> Transform {
        var bounds = CGRect.null
        for (_, r) in manager.layout.screens { bounds = bounds.union(r) }
        if bounds.isNull { bounds = CGRect(x: 0, y: 0, width: 1440, height: 900) }
        let pad = max(bounds.width, bounds.height) * 0.45
        let padded = bounds.insetBy(dx: -pad, dy: -pad)
        let scale = min(size.width / padded.width, size.height / padded.height)
        let origin = CGPoint(x: padded.midX - size.width / scale / 2, y: padded.midY - size.height / scale / 2)
        return Transform(scale: scale, origin: origin)
    }

    private var canvas: some View {
        GeometryReader { geo in
            let t = transform(in: geo.size)
            ZStack(alignment: .topLeading) {
                Color(nsColor: .underPageBackgroundColor)
                ForEach(Array(manager.layout.macDisplays.keys.sorted()), id: \.self) { uuid in
                    if let r = manager.layout.macDisplays[uuid] {
                        card(name: macName(uuid), symbol: "display", rect: r, transform: t, fill: Color.secondary.opacity(0.25), connectivity: nil, battery: nil, highlighted: false)
                    }
                }
                ForEach(Array(manager.layout.devices.keys.sorted()), id: \.self) { id in
                    if let p = manager.layout.devices[id], let d = device(id) {
                        deviceCard(d, rect: p.rect, transform: t)
                            .opacity(drag?.deviceId == id ? 0.25 : 1) // stays in the tree so its drag gesture survives
                            .gesture(dragGesture(deviceId: id, rect: p.rect, transform: t, canvasOrigin: geo.frame(in: .named("root")).origin))
                    }
                }
                if manager.layout.devices.isEmpty {
                    Text("Drag a device from the shelf and drop it against an edge of your Mac's screen.")
                        .font(.callout).foregroundStyle(.secondary).padding()
                }
            }
            .onAppear { canvasFrame = geo.frame(in: .named("root")) }
            .onChange(of: geo.size) { _, _ in canvasFrame = geo.frame(in: .named("root")) }
        }
    }

    private func macName(_ uuid: String) -> String {
        NSScreen.screens.count > 1 ? "Mac display" : "This Mac"
    }

    private func device(_ id: String) -> TrustedDevice? { trustedDevices.devices.first { $0.deviceId == id } }

    private func connectivity(_ id: String) -> Connectivity {
        DeviceConnectivity.classify(id, directIds: transport.connectedDeviceIds, meshIds: transport.meshReachableDeviceIds)
    }

    private func deviceCard(_ d: TrustedDevice, rect: CGRect, transform t: Transform) -> some View {
        card(name: d.deviceName, symbol: d.deviceType.symbolName, rect: rect, transform: t,
             fill: Color.accentColor.opacity(0.18), connectivity: connectivity(d.deviceId),
             battery: battery.batteryBySenderId[d.deviceId], highlighted: manager.activeDeviceId == d.deviceId,
             sessionState: manager.sessionStates[d.deviceId])
    }

    private func card(name: String, symbol: String, rect: CGRect, transform t: Transform, fill: Color,
                      connectivity: Connectivity?, battery: BatteryState?, highlighted: Bool,
                      sessionState: DeviceControlSession.State? = nil) -> some View {
        let frame = CGRect(origin: t.toCanvas(rect.origin), size: CGSize(width: rect.width * t.scale, height: rect.height * t.scale))
        return CardContent(name: name, symbol: symbol, connectivity: connectivity, battery: battery, highlighted: highlighted, sessionState: sessionState, fill: fill)
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
    }

    // MARK: Shelf

    private var shelf: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray").foregroundStyle(.secondary)
            if shelved.isEmpty {
                Text(androidDevices.isEmpty ? "No paired phones or tablets yet." : "Every device is in the layout. Drag one here to remove it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(shelved) { d in
                shelfItem(d)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
        .background(GeometryReader { geo in
            Color(nsColor: .controlBackgroundColor)
                .onAppear { shelfFrame = geo.frame(in: .named("root")) }
                .onChange(of: geo.size) { _, _ in shelfFrame = geo.frame(in: .named("root")) }
        })
    }

    private func shelfItem(_ d: TrustedDevice) -> some View {
        let known = manager.knownSizes[d.deviceId] ?? CGSize(width: 2000, height: 1200)
        let layoutSize = ControlLayout.deviceSize(pixelWidth: Int(known.width), pixelHeight: Int(known.height))
        let t = transform(in: canvasFrame.size == .zero ? CGSize(width: 700, height: 400) : canvasFrame.size)
        let size = CGSize(width: layoutSize.width * t.scale, height: layoutSize.height * t.scale)
        return GeometryReader { geo in
            HStack(spacing: 8) {
                Image(systemName: d.deviceType.symbolName)
                    .foregroundStyle(MenuBarView.color(for: connectivity(d.deviceId)))
                Text(d.deviceName).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named("root"))
                    .onChanged { v in
                        drag = Drag(deviceId: d.deviceId, size: size, topLeft: CGPoint(x: v.location.x - size.width / 2, y: v.location.y - size.height / 2))
                    }
                    .onEnded { v in finishDrag(at: v.location, deviceId: d.deviceId, size: size) }
            )
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
        }
        .frame(width: 170, height: 40)
    }

    // MARK: Dragging

    private func dragGesture(deviceId: String, rect: CGRect, transform t: Transform, canvasOrigin: CGPoint) -> some Gesture {
        let size = CGSize(width: rect.width * t.scale, height: rect.height * t.scale)
        let startTopLeft = CGPoint(x: canvasOrigin.x + t.toCanvas(rect.origin).x, y: canvasOrigin.y + t.toCanvas(rect.origin).y)
        return DragGesture(minimumDistance: 2, coordinateSpace: .named("root"))
            .onChanged { v in
                drag = Drag(deviceId: deviceId, size: size, topLeft: CGPoint(x: startTopLeft.x + v.translation.width, y: startTopLeft.y + v.translation.height))
            }
            .onEnded { v in
                finishDrag(at: v.location, deviceId: deviceId, size: size,
                           topLeft: CGPoint(x: startTopLeft.x + v.translation.width, y: startTopLeft.y + v.translation.height))
            }
    }

    private func finishDrag(at location: CGPoint, deviceId: String, size: CGSize, topLeft: CGPoint? = nil) {
        defer { drag = nil }
        if shelfFrame.contains(location) {
            manager.shelve(deviceId: deviceId)
            return
        }
        let tl = topLeft ?? CGPoint(x: location.x - size.width / 2, y: location.y - size.height / 2)
        let t = transform(in: canvasFrame.size)
        let inCanvas = CGPoint(x: tl.x - canvasFrame.minX, y: tl.y - canvasFrame.minY)
        let layoutOrigin = t.toLayout(inCanvas)
        // An illegal spot leaves the device where it was (or on the shelf).
        withAnimation(.spring(duration: 0.25)) { _ = manager.place(deviceId: deviceId, origin: layoutOrigin) }
    }

    @ViewBuilder
    private var ghost: some View {
        if let drag, let d = device(drag.deviceId) {
            CardContent(name: d.deviceName, symbol: d.deviceType.symbolName, connectivity: connectivity(d.deviceId),
                        battery: battery.batteryBySenderId[d.deviceId], highlighted: false, sessionState: nil,
                        fill: Color.accentColor.opacity(0.3))
                .frame(width: drag.size.width, height: drag.size.height)
                .offset(x: drag.topLeft.x, y: drag.topLeft.y)
                .allowsHitTesting(false)
        }
    }
}

private struct CardContent: View {
    let name: String
    let symbol: String
    let connectivity: Connectivity?
    let battery: BatteryState?
    let highlighted: Bool
    let sessionState: DeviceControlSession.State?
    let fill: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(fill)
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(highlighted ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: highlighted ? 3 : 1)
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title3)
                    .foregroundStyle(connectivity.map { MenuBarView.color(for: $0) } ?? .secondary)
                Text(name).font(.caption.weight(.medium)).lineLimit(1)
                if let battery {
                    Label("\(battery.level)%", systemImage: battery.isCharging ? "battery.100.bolt" : "battery.75")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let sessionState {
                    Text(statusText(sessionState)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(4)
        }
    }

    private func statusText(_ s: DeviceControlSession.State) -> String {
        switch s {
        case .idle: return "Idle"
        case .negotiating, .connecting: return "Connecting…"
        case .ready: return "Ready"
        case .backoff(let reason): return reason
        }
    }
}
