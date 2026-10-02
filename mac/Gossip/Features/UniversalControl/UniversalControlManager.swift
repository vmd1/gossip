import Foundation
import Combine
import CoreGraphics

/// One input event, already reduced to what the crossing logic needs. Produced by `ControlEventTap` from
/// `CGEvent`s (or by tests / the scripted E2E CLI).
enum ControlInputEvent: Equatable {
    case mouseMoved(delta: CGPoint, location: CGPoint)
    /// `button`: 0 = primary, 1 = secondary, 2 = middle, 3 = back, 4 = forward.
    case button(index: Int, down: Bool, location: CGPoint)
    /// Scroll in 1/120 notch units, positive y = up.
    case scroll(dx: Int, dy: Int)
    case key(keyCode: UInt16, down: Bool, isRepeat: Bool, characters: String?, flags: ControlModifierFlags)
    /// A modifier key changed state (`down` already resolved from the device-dependent flag bits).
    case modifier(keyCode: UInt16, down: Bool)
}

struct ControlModifierFlags: OptionSet, Equatable {
    let rawValue: Int
    static let shift = ControlModifierFlags(rawValue: 1)
    static let control = ControlModifierFlags(rawValue: 2)
    static let option = ControlModifierFlags(rawValue: 4)
    static let command = ControlModifierFlags(rawValue: 8)
}

enum ControlDisposition { case pass, swallow }

/// Hides, freezes, warps and restores the real Mac cursor. The real one is `SystemCursorController`.
protocol ControlCursorController: AnyObject {
    /// Remote mode starts: hide the cursor and stop it following the mouse.
    func freeze()
    func warp(to point: CGPoint)
    /// Remote mode ends: reassociate the mouse with the cursor and show it again. Idempotent.
    func restore()
}

enum ControlTypingMode: String, CaseIterable {
    /// Printable keys send the typed character (correct on non-US layouts); shortcuts and control keys send key codes.
    case characters
    /// Everything is a key code.
    case keys
}

/// Settings for Universal Control, persisted in `UserDefaults` (per Mac, never sent over the wire).
enum UniversalControlSettings {
    private static let commandKey = "universalControl.commandMapping"
    private static let typingKey = "universalControl.typingMode"

    static var commandMapping: HIDKeyTable.CommandMapping {
        get { UserDefaults.standard.string(forKey: commandKey).flatMap(HIDKeyTable.CommandMapping.init(rawValue:)) ?? .control }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: commandKey) }
    }

    static var typingMode: ControlTypingMode {
        get { UserDefaults.standard.string(forKey: typingKey).flatMap(ControlTypingMode.init(rawValue:)) ?? .characters }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: typingKey) }
    }
}

/// Owns one warm `ControlSession` per placed, directly-connected, enabled device and the crossing engine
/// that routes the Mac's mouse and keyboard to whichever of them has the pointer.
///
/// Thread model: `handle(_:)` runs on the event-tap thread and must answer pass/swallow synchronously, so
/// the router, held-key state and frame sending sit behind `lock`; everything published to SwiftUI is hopped
/// to the main thread. Sessions are created and stopped on the main thread.
final class UniversalControlManager: ObservableObject {
    @Published private(set) var layout: ControlLayout
    @Published private(set) var sessionStates: [String: DeviceControlSession.State] = [:]
    /// The device that currently has the pointer, if any.
    @Published private(set) var activeDeviceId: String?
    /// Last-known logical pixel size per device, so the layout window can size a card before first connect.
    @Published private(set) var knownSizes: [String: CGSize] = [:]

    typealias SessionFactory = (_ deviceId: String) -> ControlSession

    private let makeSession: SessionFactory
    private let cursor: ControlCursorController
    private let store: ControlLayoutStore?
    private let isFeatureEnabled: () -> Bool
    private let isDirectlyConnected: (String) -> Bool
    private let macDisplays: () -> [String: CGRect]
    private let commandMapping: () -> HIDKeyTable.CommandMapping
    private let typingMode: () -> ControlTypingMode

    private let lock = NSLock()
    private var router: PointerRouter
    /// Mutated on the main thread only; read from the event-tap thread, hence the lock.
    private let sessionsLock = NSLock()
    private var _sessions: [String: ControlSession] = [:]
    private var sessions: [String: ControlSession] {
        get { sessionsLock.lock(); defer { sessionsLock.unlock() }; return _sessions }
        set { sessionsLock.lock(); _sessions = newValue; sessionsLock.unlock() }
    }
    private var buttonMask: UInt8 = 0                       // lock
    private var heldUsages: Set<UInt16> = []                // lock
    private var moveRemainder: CGPoint = .zero              // lock
    private var cursorFrozen = false                        // lock
    private var running = false
    private var reconcileTimer: Timer?

    init(
        mesh: ControlMesh,
        makeSession: @escaping SessionFactory,
        cursor: ControlCursorController,
        store: ControlLayoutStore? = ControlLayoutStore(),
        macDisplays: @escaping () -> [String: CGRect],
        isFeatureEnabled: @escaping () -> Bool = { FeatureSettings.shared.isEnabled(.universalControl) },
        commandMapping: @escaping () -> HIDKeyTable.CommandMapping = { UniversalControlSettings.commandMapping },
        typingMode: @escaping () -> ControlTypingMode = { UniversalControlSettings.typingMode }
    ) {
        self.makeSession = makeSession
        self.cursor = cursor
        self.store = store
        self.macDisplays = macDisplays
        self.isFeatureEnabled = isFeatureEnabled
        self.isDirectlyConnected = { mesh.isDirectlyConnected($0) }
        self.commandMapping = commandMapping
        self.typingMode = typingMode

        var initial = ControlLayout(macDisplays: macDisplays(), devices: store?.loadPlacements() ?? [:])
        initial.normalize()
        layout = initial
        router = PointerRouter(layout: initial)
        router.pointerGain = ControlLayout.expectedDeviceAcceleration
        knownSizes = store?.loadSizes() ?? [:]
    }

    // MARK: Lifecycle

    /// Starts reconciling sessions (and a 5 s self-healing pass). Main thread.
    func start() {
        guard !running else { return }
        running = true
        reconcile()
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.reconcile() }
    }

    /// Stops every session and returns the pointer to the Mac. Main thread.
    func stop() {
        running = false
        reconcileTimer?.invalidate(); reconcileTimer = nil
        returnToMac()
        for (_, s) in sessions { s.stop() }
        sessions.removeAll()
        sessionStates.removeAll()
    }

    /// Brings the set of sessions in line with the layout, the feature toggle and who is directly connected.
    func reconcile() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard running else { return }
        let enabled = isFeatureEnabled()
        let desired: Set<String> = enabled ? Set(layout.devices.keys.filter { isDirectlyConnected($0) }) : []
        for id in sessions.keys where !desired.contains(id) { removeSession(id) }
        for id in desired where sessions[id] == nil { addSession(id) }
        syncReady()
    }

    private func addSession(_ id: String) {
        let s = makeSession(id)
        s.onChange = { [weak self] in DispatchQueue.main.async { self?.sessionChanged(id) } }
        s.onDisplayInfo = { [weak self] info in DispatchQueue.main.async { self?.applyDisplayInfo(id, info) } }
        sessions[id] = s
        s.start()
        sessionStates[id] = s.state
    }

    private func removeSession(_ id: String) {
        guard let s = sessions.removeValue(forKey: id) else { return }
        applyActions(withLock: { $0.deviceBecameUnavailable(id) })
        s.onChange = nil; s.onDisplayInfo = nil
        s.stop()
        sessionStates[id] = nil
    }

    private func sessionChanged(_ id: String) {
        guard let s = sessions[id] else { return }
        sessionStates[id] = s.state
        syncReady()
    }

    private func syncReady() {
        let ready = Set(sessions.filter { $0.value.state == .ready }.keys)
        applyActions(withLock: { router -> [PointerRouter.Action] in
            let previous = router.readyDevices
            router.readyDevices = ready
            var actions: [PointerRouter.Action] = []
            for gone in previous.subtracting(ready) { actions += router.deviceBecameUnavailable(gone) }
            return actions
        })
    }

    private func applyDisplayInfo(_ id: String, _ info: ControlDisplayInfo) {
        applyAdvertisedSize(deviceId: id, width: info.width, height: info.height)
    }

    /// Records a device's real display size, from a live session or a `display.info` message (which arrives
    /// without any session, so cards are right before the first connect). A repeat is a no-op.
    func applyAdvertisedSize(deviceId id: String, width: Int, height: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard width > 0, height > 0 else { return }
        let size = CGSize(width: width, height: height)
        if knownSizes[id] != size {
            knownSizes[id] = size
            store?.saveSizes(knownSizes)
        }
        guard layout.isPlaced(id) else { return }
        var updated = layout
        let shelved = updated.resize(deviceId: id, to: ControlLayout.deviceSize(pixelWidth: width, pixelHeight: height))
        if updated != layout { commit(updated, shelved: shelved) }
    }

    // MARK: Layout editing (main thread)

    func displaysChanged() {
        var updated = layout
        let shelved = updated.setMacDisplays(macDisplays())
        commit(updated, shelved: shelved)
    }

    /// Drops `deviceId` into the layout at `origin` (snapped). Returns false if there is no legal spot.
    @discardableResult
    func place(deviceId: String, origin: CGPoint, fallbackPixelSize: CGSize = CGSize(width: 2000, height: 1200),
               snapDistance: Double = ControlLayout.snapDistance, captureDistance: Double = 0) -> Bool {
        var updated = layout
        let pixels = knownSizes[deviceId] ?? fallbackPixelSize
        let size = ControlLayout.deviceSize(pixelWidth: Int(pixels.width), pixelHeight: Int(pixels.height))
        let current = layout.devices[deviceId].map { CGSize(width: $0.width, height: $0.height) } ?? size
        guard updated.place(deviceId: deviceId, size: current, proposedOrigin: origin,
                            snapDistance: snapDistance, captureDistance: captureDistance) != nil else { return false }
        commit(updated, shelved: [])
        return true
    }

    func shelve(deviceId: String) {
        var updated = layout
        let removed = updated.remove(deviceId: deviceId)
        commit(updated, shelved: removed)
    }

    private func commit(_ updated: ControlLayout, shelved: [String]) {
        layout = updated
        store?.savePlacements(updated.devices)
        applyActions(withLock: { $0.setLayout(updated) })
        reconcile()
    }

    /// Escape hatch: put the pointer back on the Mac now.
    func returnToMac() {
        applyActions(withLock: { $0.forceReturn(nearestTo: nil) })
    }

    // MARK: Event handling (event-tap thread)

    func handle(_ event: ControlInputEvent) -> ControlDisposition {
        // Local, un-captured events must not wait for anything slow.
        lock.lock()
        let wasRemote = router.state.remoteDeviceId != nil
        var disposition: ControlDisposition = wasRemote ? .swallow : .pass
        var actions: [PointerRouter.Action] = []

        switch event {
        case .mouseMoved(let delta, let location):
            if wasRemote {
                actions = router.remoteMoved(delta: delta)
            } else {
                actions = router.macMoved(delta: delta, location: location)
                // The move that crosses is swallowed so the Mac cursor doesn't also move.
                if router.state.remoteDeviceId != nil { disposition = .swallow }
            }
        case .button(let index, let down, _):
            if wasRemote, let id = router.state.remoteDeviceId {
                let bit = UInt8(1) << UInt8(min(max(index, 0), 7))
                buttonMask = down ? (buttonMask | bit) : (buttonMask & ~bit)
                transmit(.buttons(buttonMask), to: id)
            }
        case .scroll(let dx, let dy):
            if wasRemote, let id = router.state.remoteDeviceId {
                transmit(.scroll(dx: Int16(clamping: dx), dy: Int16(clamping: dy)), to: id)
            }
        case .modifier(let keyCode, let down):
            if wasRemote, let id = router.state.remoteDeviceId,
               let usage = HIDKeyTable.usage(forMacKeyCode: keyCode, command: commandMapping()) {
                if keyCode == 57 { // Caps Lock reports a toggle, not press and release
                    transmit(.key(usage: usage, down: true, modifiers: currentModifierByte()), to: id)
                    transmit(.key(usage: usage, down: false, modifiers: currentModifierByte()), to: id)
                } else if down { heldUsages.insert(usage) } else { heldUsages.remove(usage) }
                transmit(.key(usage: usage, down: down, modifiers: currentModifierByte()), to: id)
            }
        case .key(let keyCode, let down, _, let characters, let flags):
            if down, keyCode == 53, flags.isSuperset(of: [.control, .option, .command]) {
                // Escape hatch: Control+Option+Command+Escape returns to the Mac from anywhere.
                actions = router.forceReturn(nearestTo: nil)
                disposition = wasRemote ? .swallow : .pass
            } else if wasRemote, let id = router.state.remoteDeviceId {
                handleKey(keyCode: keyCode, down: down, characters: characters, flags: flags, to: id)
            }
        }

        let sideEffects = perform(actions)
        lock.unlock()
        sideEffects()
        return disposition
    }

    private func handleKey(keyCode: UInt16, down: Bool, characters: String?, flags: ControlModifierFlags, to id: String) {
        let mapping = commandMapping()
        // Printable text without Control/Command goes as characters (right on non-US layouts); the rest as key codes.
        if typingMode() == .characters, !flags.contains(.control), !flags.contains(.command),
           let characters, Self.isPrintable(characters) {
            if down { transmit(.text(characters), to: id) }
            return
        }
        guard let usage = HIDKeyTable.usage(forMacKeyCode: keyCode, command: mapping) else { return }
        if down { heldUsages.insert(usage) } else { heldUsages.remove(usage) }
        transmit(.key(usage: usage, down: down, modifiers: currentModifierByte()), to: id)
    }

    private func currentModifierByte() -> UInt8 {
        var m: UInt8 = 0
        for u in heldUsages where u >= 0xE0 && u <= 0xE7 { m |= UInt8(1) << UInt8(u - 0xE0) }
        return m
    }

    static func isPrintable(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) }
    }

    // MARK: Actions

    /// Applies a router action batch triggered outside the event path (layout change, session loss).
    private func applyActions(withLock body: (inout PointerRouter) -> [PointerRouter.Action]) {
        lock.lock()
        let actions = body(&router)
        let sideEffects = perform(actions)
        lock.unlock()
        sideEffects()
    }

    /// Executes frame sends under the lock and returns the cursor / UI work to run after it is released.
    private func perform(_ actions: [PointerRouter.Action]) -> () -> Void {
        var after: [() -> Void] = []
        for action in actions {
            switch action {
            case .enter(let id, let edge, let fraction):
                buttonMask = 0; moveRemainder = .zero
                transmit(.enter(edge: edge, position: UInt16(max(0, min(1, fraction)) * 65535)), to: id)
                if !cursorFrozen {
                    cursorFrozen = true
                    after.append { [cursor] in cursor.freeze() }
                }
                after.append { [weak self] in DispatchQueue.main.async { self?.activeDeviceId = id } }
            case .leave(let id):
                // Release anything held so nothing stays stuck on the device.
                if buttonMask != 0 { buttonMask = 0; transmit(.buttons(0), to: id) }
                for usage in heldUsages { transmit(.key(usage: usage, down: false, modifiers: 0), to: id) }
                heldUsages.removeAll()
                transmit(.leave, to: id)
                after.append { [weak self] in DispatchQueue.main.async { if self?.activeDeviceId == id { self?.activeDeviceId = nil } } }
            case .move(let id, let dx, let dy):
                let scale = ControlLayout.defaultPixelsPerPoint
                let x = dx * scale + moveRemainder.x, y = dy * scale + moveRemainder.y
                let (ix, iy) = (x.rounded(.towardZero), y.rounded(.towardZero))
                moveRemainder = CGPoint(x: x - ix, y: y - iy)
                var rx = ix, ry = iy
                while rx != 0 || ry != 0 { // a frame carries Int16
                    let cx = max(-32000, min(32000, rx)), cy = max(-32000, min(32000, ry))
                    transmit(.mouseMove(dx: Int16(cx), dy: Int16(cy)), to: id)
                    rx -= cx; ry -= cy
                }
            case .warpMacCursor(let point):
                let wasFrozen = cursorFrozen
                cursorFrozen = false
                after.append { [cursor] in
                    cursor.warp(to: point)
                    if wasFrozen { cursor.restore() }
                }
            }
        }
        return { after.forEach { $0() } }
    }

    private func transmit(_ frame: ControlFrame, to id: String) {
        // The session objects themselves are thread-safe to `send`.
        sessions[id]?.send(frame)
    }

    // MARK: Mesh messages

    /// `display.info`: a device's real display size, sent without any control session. Idempotent.
    func handleDisplayInfo(_ envelope: Envelope) {
        guard let size = Self.parseDisplaySize(envelope.payload) else { return }
        let id = envelope.senderId
        DispatchQueue.main.async { [weak self] in self?.applyAdvertisedSize(deviceId: id, width: size.width, height: size.height) }
    }

    static func parseDisplaySize(_ payload: JSONValue) -> (width: Int, height: Int)? {
        guard let w = payload["width"]?.numberValue, let h = payload["height"]?.numberValue,
              w >= 1, h >= 1, w <= 20_000, h <= 20_000 else { return nil }
        return (Int(w), Int(h))
    }

    func handleMesh(_ envelope: Envelope) {
        DispatchQueue.main.async { [weak self] in
            self?.sessions[envelope.senderId]?.handleMesh(type: envelope.type, payload: envelope.payload, from: envelope.senderId)
        }
    }
}
