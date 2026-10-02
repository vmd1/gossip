import Foundation
import Security

/// What a session needs from the mesh. `TransportManager` implements it in the app; tests use a fake that
/// plays the device's part.
protocol ControlMesh: AnyObject {
    /// `control.*` messages carry key material, so they must only ever travel over a *direct* connection.
    func isDirectlyConnected(_ deviceId: String) -> Bool
    func host(for deviceId: String) -> String?
    func sendControl(type: String, to deviceId: String, payload: [String: JSONValue])
}

/// What the manager needs from a per-device session; lets the crossing logic run against fakes.
protocol ControlSession: AnyObject {
    var deviceId: String { get }
    var state: DeviceControlSession.State { get }
    var displayInfo: ControlDisplayInfo? { get }
    var onChange: (() -> Void)? { get set }
    var onDisplayInfo: ((ControlDisplayInfo) -> Void)? { get set }
    func start()
    func stop()
    func send(_ frame: ControlFrame)
    func handleMesh(type: String, payload: JSONValue, from senderId: String)
}

/// One warm, encrypted session to one device, with its own state, backoff reconnect and failure isolation.
///
/// Every (re)connection gets a fresh `sessionId` and `secret`: the data channel uses counter nonces, so a key
/// must never be reused across two connections. Flow: `control.session_start{sessionId,secret,backend}` over
/// the mesh -> device answers `control.ready{sessionId,port,width,height,rotation,backend}` (or
/// `control.error`) -> dial the WebSocket and exchange the encrypted hello. `session_start` is idempotent on
/// the device, so it is re-sent until `ready` arrives.
final class DeviceControlSession: ControlSession {
    enum State: Equatable {
        case idle
        case negotiating
        case connecting
        case ready
        /// Waiting to retry after a failure.
        case backoff(reason: String)

        var isActive: Bool { self != .idle }
    }

    struct Timing {
        var retryStart: TimeInterval = 2.5
        var negotiationTimeout: TimeInterval = 15
        var backoffInitial: TimeInterval = 1
        var backoffMax: TimeInterval = 30
        var pingInterval: TimeInterval = 4
        var deadAfter: TimeInterval = 12
    }

    let deviceId: String
    private let mesh: ControlMesh
    private let selfId: String
    private let timing: Timing
    private let backendPreference: String

    private let lock = NSLock()
    private var _state: State = .idle
    private var _displayInfo: ControlDisplayInfo?
    private var client: ControlWebSocketClient?     // guarded by `lock`; only set while connecting/ready
    private var readyClient: ControlWebSocketClient? // guarded by `lock`; set only when ready

    // Main-queue confined:
    private var sessionId: String?
    private var secret: Data?
    private var attemptStartedAt = Date()
    private var retryTimer: Timer?
    private var pingTimer: Timer?
    private var lastHeard = Date()
    private var readySince: Date?
    private var backoff: TimeInterval
    private var backoffWork: DispatchWorkItem?
    private var wanted = false

    var onChange: (() -> Void)?
    var onDisplayInfo: ((ControlDisplayInfo) -> Void)?

    var state: State { lock.lock(); defer { lock.unlock() }; return _state }
    var displayInfo: ControlDisplayInfo? { lock.lock(); defer { lock.unlock() }; return _displayInfo }

    init(deviceId: String, mesh: ControlMesh, selfId: String, backend: String = "auto", timing: Timing = Timing()) {
        self.deviceId = deviceId
        self.mesh = mesh
        self.selfId = selfId
        self.timing = timing
        self.backendPreference = backend
        self.backoff = timing.backoffInitial
    }

    // MARK: Lifecycle (call on main)

    func start() {
        wanted = true
        guard state == .idle || isBackoff else { return }
        beginAttempt()
    }

    func stop() {
        wanted = false
        endAttempt(notifyDevice: true)
        set(.idle)
    }

    private var isBackoff: Bool { if case .backoff = state { return true } else { return false } }

    private func beginAttempt() {
        backoffWork?.cancel(); backoffWork = nil
        guard wanted else { return }
        guard mesh.isDirectlyConnected(deviceId) else { return fail("not directly connected") }
        let id = UUID().uuidString
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return fail("no randomness") }
        sessionId = id
        secret = Data(bytes)
        attemptStartedAt = Date()
        set(.negotiating)
        sendStart()
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: timing.retryStart, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            guard self.state == .negotiating else { return timer.invalidate() }
            if Date().timeIntervalSince(self.attemptStartedAt) > self.timing.negotiationTimeout {
                timer.invalidate()
                self.fail("device didn't respond")
            } else {
                self.sendStart()
            }
        }
    }

    private func sendStart() {
        guard let sessionId, let secret else { return }
        mesh.sendControl(type: "control.session_start", to: deviceId, payload: [
            "sessionId": .string(sessionId),
            "secret": .string(secret.base64EncodedString()),
            "backend": .string(backendPreference),
        ])
    }

    /// Tears down the current attempt (client + timers); optionally tells the device with `control.end`.
    private func endAttempt(notifyDevice: Bool) {
        retryTimer?.invalidate(); retryTimer = nil
        pingTimer?.invalidate(); pingTimer = nil
        backoffWork?.cancel(); backoffWork = nil
        lock.lock()
        let c = client
        client = nil; readyClient = nil
        lock.unlock()
        c?.onEvent = nil
        c?.close()
        if notifyDevice, let sessionId, mesh.isDirectlyConnected(deviceId) {
            mesh.sendControl(type: "control.end", to: deviceId, payload: ["sessionId": .string(sessionId)])
        }
        sessionId = nil; secret = nil; readySince = nil
    }

    private func fail(_ reason: String) {
        NSLog("Gossip: universal control session to \(deviceId) failed: \(reason)")
        let wasLongLived = readySince.map { Date().timeIntervalSince($0) > 10 } ?? false
        endAttempt(notifyDevice: true)
        guard wanted else { return set(.idle) }
        if wasLongLived { backoff = timing.backoffInitial }
        set(.backoff(reason: reason))
        let delay = backoff
        backoff = min(backoff * 2, timing.backoffMax)
        let work = DispatchWorkItem { [weak self] in self?.beginAttempt() }
        backoffWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func set(_ new: State) {
        lock.lock()
        let changed = _state != new
        _state = new
        lock.unlock()
        if changed { onChange?() }
    }

    // MARK: Mesh replies

    func handleMesh(type: String, payload: JSONValue, from senderId: String) {
        guard senderId == deviceId, let id = payload["sessionId"]?.stringValue, id == sessionId else { return }
        switch type {
        case "control.ready":
            // Idempotent: the device re-sends `ready` for each duplicate start.
            guard state == .negotiating,
                  let port = payload["port"]?.numberValue, port > 0, port < 65536,
                  let host = mesh.host(for: deviceId), let secret else { return }
            retryTimer?.invalidate(); retryTimer = nil
            connect(host: host, port: UInt16(port), sessionId: id, secret: secret)
        case "control.error":
            fail(payload["reason"]?.stringValue ?? "device error")
        case "control.end":
            fail("ended by device")
        default:
            break
        }
    }

    private func connect(host: String, port: UInt16, sessionId: String, secret: Data) {
        set(.connecting)
        guard let c = ControlWebSocketClient(host: host, port: port, sessionId: sessionId, secret: secret, label: String(deviceId.prefix(8))) else {
            return fail("bad address")
        }
        lock.lock(); client = c; lock.unlock()
        c.onEvent = { [weak self, weak c] event in
            DispatchQueue.main.async { [weak self, weak c] in
                guard let self, let c, self.isCurrent(c) else { return }
                self.handle(event, from: c)
            }
        }
        c.connect()
    }

    private func isCurrent(_ c: ControlWebSocketClient) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return client === c
    }

    private func handle(_ event: ControlWebSocketClient.Event, from c: ControlWebSocketClient) {
        lastHeard = Date()
        switch event {
        case .ready(let info):
            lock.lock(); readyClient = c; _displayInfo = info; lock.unlock()
            readySince = Date()
            set(.ready)
            onDisplayInfo?(info)
            startPinging()
        case .frame(let frame):
            switch frame {
            case .displayInfo(let info):
                lock.lock(); _displayInfo = info; lock.unlock()
                onDisplayInfo?(info)
            case .error(let reason):
                fail(reason)
            default:
                break // pong etc.: `lastHeard` already updated
            }
        case .closed(let error):
            fail(error.map { "connection lost (\($0.localizedDescription))" } ?? "connection closed")
        }
    }

    private func startPinging() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: timing.pingInterval, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            guard self.state == .ready else { return timer.invalidate() }
            if Date().timeIntervalSince(self.lastHeard) > self.timing.deadAfter {
                timer.invalidate()
                self.fail("device stopped answering")
            } else {
                self.send(.ping)
            }
        }
    }

    // MARK: Sending (any thread)

    func send(_ frame: ControlFrame) {
        lock.lock(); let c = readyClient; lock.unlock()
        c?.send(frame)
    }
}
