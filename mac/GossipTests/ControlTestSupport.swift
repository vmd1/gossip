import Foundation
import Network
import CryptoKit
@testable import Gossip

/// Records the Mac cursor operations.
final class FakeCursor: ControlCursorController {
    private let lock = NSLock()
    private var _log: [String] = []
    var log: [String] { lock.lock(); defer { lock.unlock() }; return _log }
    private func add(_ s: String) { lock.lock(); _log.append(s); lock.unlock() }
    func freeze() { add("freeze") }
    func warp(to point: CGPoint) { add("warp(\(Int(point.x)),\(Int(point.y)))") }
    func restore() { add("restore") }
}

/// A session stand-in that records every frame the manager sends it.
final class FakeControlSession: ControlSession {
    let deviceId: String
    private let lock = NSLock()
    private var _state: DeviceControlSession.State = .idle
    private var _frames: [ControlFrame] = []
    var onChange: (() -> Void)?
    var onDisplayInfo: ((ControlDisplayInfo) -> Void)?
    var onCursorReport: ((UInt8, UInt16, UInt16, UInt32) -> Void)?
    var displayInfo: ControlDisplayInfo? { ControlDisplayInfo(width: 2000, height: 1200, rotation: 0, backend: 0) }
    var state: DeviceControlSession.State { lock.lock(); defer { lock.unlock() }; return _state }
    var frames: [ControlFrame] { lock.lock(); defer { lock.unlock() }; return _frames }
    init(deviceId: String) { self.deviceId = deviceId }
    func start() {}
    func stop() { setState(.idle) }
    func send(_ frame: ControlFrame) { lock.lock(); _frames.append(frame); lock.unlock() }
    func handleMesh(type: String, payload: JSONValue, from senderId: String) {}
    func setState(_ s: DeviceControlSession.State) { lock.lock(); _state = s; lock.unlock(); onChange?() }
}

/// An in-process device: a loopback WebSocket server that answers the encrypted hello and records every
/// decrypted frame it receives, exactly like the Android bridge would.
final class FakeControlDevice {
    let deviceId: String
    private let queue = DispatchQueue(label: "fake.device")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var cipher: ControlCipher?
    private var sessionId = ""
    private let lock = NSLock()
    private var _frames: [ControlFrame] = []
    private(set) var port: UInt16 = 0
    var displayInfo = ControlDisplayInfo(width: 2000, height: 1200, rotation: 0, backend: 0)
    /// If set, the device never answers the hello.
    var muted = false

    var frames: [ControlFrame] { lock.lock(); defer { lock.unlock() }; return _frames }
    var helloReceived: Bool { frames.contains { if case .hello = $0 { return true } else { return false } } }

    init(deviceId: String) { self.deviceId = deviceId }

    /// Starts listening for a session. Idempotent per sessionId (like the real device's `control.session_start`).
    func open(sessionId: String, secret: Data) throws -> UInt16 {
        if self.sessionId == sessionId, port != 0 { return port }
        close()
        self.sessionId = sessionId
        cipher = ControlCipher(secret: secret, sessionId: sessionId, role: .deviceToMac)
        let ws = NWProtocolWebSocket.Options()
        let params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredInterfaceType = .loopback
        let l = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        l.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            self.connection?.cancel()
            self.connection = c
            c.start(queue: self.queue)
            self.receive(c)
        }
        l.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        listener = l
        port = l.port?.rawValue ?? 0
        return port
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, context, _, error in
            guard let self, error == nil else { return }
            if let data, !data.isEmpty, var cipher = self.cipher {
                if let frame = try? cipher.open(data) {
                    self.cipher = cipher
                    self.lock.lock(); self._frames.append(frame); self.lock.unlock()
                    if case .hello = frame, !self.muted { self.send(.helloAck(self.displayInfo), on: c) }
                    if case .ping = frame, !self.muted { self.send(.pong, on: c) }
                }
            }
            self.receive(c)
        }
    }

    private func send(_ frame: ControlFrame, on c: NWConnection) {
        guard var cipher else { return }
        guard let data = try? cipher.seal(frame) else { return }
        self.cipher = cipher
        let md = NWProtocolWebSocket.Metadata(opcode: .binary)
        c.send(content: data, contentContext: NWConnection.ContentContext(identifier: "ws", metadata: [md]), isComplete: true, completion: .idempotent)
    }

    func sendToMac(_ frame: ControlFrame) { queue.async { if let c = self.connection { self.send(frame, on: c) } } }

    /// Drops the client's connection (a network failure).
    func dropConnection() { queue.async { self.connection?.cancel() } }

    func close() {
        connection?.cancel(); connection = nil
        listener?.cancel(); listener = nil
        port = 0; sessionId = ""
    }
}

/// A mesh that plays the part of the devices' Android side: `control.session_start` makes the matching
/// `FakeControlDevice` listen and `control.ready` is delivered back to the session.
final class FakeMesh: ControlMesh {
    var devices: [String: FakeControlDevice] = [:]
    var sessions: [String: DeviceControlSession] = [:]
    private let lock = NSLock()
    private var connected: Set<String> = []
    private(set) var sent: [(type: String, deviceId: String)] = []
    /// While true, `control.ready` is not delivered (the device is unresponsive).
    var silent = false

    func setConnected(_ id: String, _ value: Bool) {
        lock.lock(); if value { connected.insert(id) } else { connected.remove(id) }; lock.unlock()
    }
    func isDirectlyConnected(_ deviceId: String) -> Bool { lock.lock(); defer { lock.unlock() }; return connected.contains(deviceId) }
    func host(for deviceId: String) -> String? { "127.0.0.1" }

    func sendControl(type: String, to deviceId: String, payload: [String: JSONValue]) {
        lock.lock(); sent.append((type, deviceId)); lock.unlock()
        guard type == "control.session_start", !silent, let device = devices[deviceId],
              let sid = payload["sessionId"]?.stringValue, let secretB64 = payload["secret"]?.stringValue,
              let secret = Data(base64Encoded: secretB64) else { return }
        guard let port = try? device.open(sessionId: sid, secret: secret) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.sessions[deviceId]?.handleMesh(type: "control.ready", payload: .object([
                "sessionId": .string(sid), "port": .number(Double(port)),
                "width": .number(Double(device.displayInfo.width)), "height": .number(Double(device.displayInfo.height)),
                "rotation": .number(0), "backend": .string("uhid"),
            ]), from: deviceId)
        }
    }
}

func waitUntil(timeout: TimeInterval = 8, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    return condition()
}
