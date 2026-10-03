import AppKit
import Combine
import Foundation

/// On-device screen mirroring, viewer side. The phone runs the capture (a bundled scrcpy server
/// launched through Shizuku — see `android/screen-server/README.md`); this controller only
/// negotiates a session over the Noise-encrypted mesh, connects to the phone's WebSocket bridge,
/// and shows the stream in a `ScreenMirrorWindow`. Nothing here needs `adb` or `scrcpy`.
///
/// Flow: `screen.start{sessionId,...}` → phone replies `screen.ready{sessionId,port,token}` (or
/// `screen.error{sessionId,reason}`) → connect `ws://<phone>:<port>`, send the token → header +
/// video. `screen.start` is idempotent on the phone, so a lost `screen.ready` is recovered by
/// simply re-sending it with the same `sessionId` (done every `retryInterval` until it arrives
/// or `readyTimeout` passes). Closing the window / "Stop Mirroring" sends `screen.stop`.
final class ScreenMirrorController: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case mirroring
    }

    @Published private(set) var state: State = .idle

    /// Which trusted device (by Gossip `deviceId`) the current/last session targets, so the
    /// menu can show "Stop Mirroring" on the right row — only one session runs at a time.
    @Published private(set) var mirroringDeviceId: String?

    /// Human-readable reason the last attempt failed, shown in the menu until the next attempt.
    /// The last start/session error, shown in the menu. Clears itself after `errorLifetime` so a stale
    /// message never lingers.
    @Published private(set) var lastError: String? {
        didSet {
            errorClearWork?.cancel()
            errorClearWork = nil
            guard let message = lastError else { return }
            let work = DispatchWorkItem { [weak self] in
                if self?.lastError == message { self?.lastError = nil }
            }
            errorClearWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.errorLifetime, execute: work)
        }
    }
    static let errorLifetime: TimeInterval = 10
    private var errorClearWork: DispatchWorkItem?

    private static let retryInterval: TimeInterval = 2.5
    private static let readyTimeout: TimeInterval = 20

    private final class Session {
        let id = UUID().uuidString
        let deviceId: String
        let deviceName: String
        let transport: TransportManager
        let startedAt = Date()
        var retryTimer: Timer?
        var client: ScreenBridgeClient?
        var window: ScreenMirrorWindow?
        var audioPlayer: ScreenAudioPlayer?
        init(deviceId: String, deviceName: String, transport: TransportManager) {
            self.deviceId = deviceId; self.deviceName = deviceName; self.transport = transport
        }
    }

    private var session: Session?
    private var routerRegistered = false

    /// Starts mirroring `deviceId`. Must be called on the main thread. The device must currently
    /// be connected over the mesh (the session is negotiated there and the viewer dials the
    /// address the mesh connection came from).
    func start(deviceId: String, deviceName: String, transport: TransportManager) {
        guard case .idle = state else { return }
        lastError = nil
        guard FeatureSettings.shared.isEnabled(.screenMirroring) else {
            lastError = "Screen mirroring is turned off in Settings."
            return
        }
        guard transport.hostWithZone(for: deviceId) != nil else {
            lastError = "\(deviceName) isn't connected right now."
            return
        }
        registerRouterIfNeeded(transport)
        let s = Session(deviceId: deviceId, deviceName: deviceName, transport: transport)
        session = s
        state = .starting
        mirroringDeviceId = deviceId
        sendStart(s)
        s.retryTimer = Timer.scheduledTimer(withTimeInterval: Self.retryInterval, repeats: true) { [weak self, weak s] timer in
            guard let self, let s, self.session === s else { return timer.invalidate() }
            if Date().timeIntervalSince(s.startedAt) > Self.readyTimeout {
                self.fail(s, "\(deviceName) didn't respond. Is Gossip updated on the phone?")
            } else {
                self.sendStart(s)
            }
        }
    }

    /// Ends the current session (menu "Stop Mirroring" or window closed). Idempotent.
    func stop() {
        guard let s = session else { return }
        send(type: "screen.stop", for: s)
        teardown(s)
    }

    // MARK: - Messages

    private func registerRouterIfNeeded(_ transport: TransportManager) {
        guard !routerRegistered else { return }
        routerRegistered = true
        transport.router.register(prefix: "screen.") { [weak self] envelope in
            DispatchQueue.main.async { self?.handle(envelope) }
        }
    }

    private func handle(_ envelope: Envelope) {
        guard let s = session else { return }
        guard envelope.payload["sessionId"]?.stringValue == s.id, envelope.senderId == s.deviceId else {
            NSLog("Gossip: ignoring \(envelope.type) (session/sender mismatch: sender=\(envelope.senderId) expected=\(s.deviceId))")
            return
        }
        NSLog("Gossip: received \(envelope.type) for session \(s.id)")
        switch envelope.type {
        case "screen.ready":
            // Idempotent: the phone re-sends `screen.ready` for every duplicate start we send.
            guard s.client == nil,
                  let port = envelope.payload["port"]?.numberValue,
                  let token = envelope.payload["token"]?.stringValue,
                  let host = s.transport.hostWithZone(for: s.deviceId) else { return }
            connect(s, host: host, port: UInt16(clamping: Int(port)), token: token)
        case "screen.error":
            let reason = envelope.payload["reason"]?.stringValue ?? "unknown"
            fail(s, Self.message(forErrorReason: reason, deviceName: s.deviceName))
        default:
            break
        }
    }

    private static func message(forErrorReason reason: String, deviceName: String) -> String {
        switch reason {
        case "shizuku_unavailable":
            return "Shizuku isn't running on \(deviceName). Start it (it needs re-activating after every reboot) and allow Gossip."
        case "feature_disabled":
            return "Screen mirroring is turned off on \(deviceName). Turn it on in Gossip's settings there."
        case "capture_failed":
            return "\(deviceName) couldn't start screen capture. Check Shizuku and try again."
        default:
            return "\(deviceName) couldn't start mirroring (\(reason))."
        }
    }

    private func sendStart(_ s: Session) {
        send(type: "screen.start", for: s, extra: ["maxSize": .number(1600), "bitRate": .number(8_000_000), "maxFps": .number(60), "audio": .bool(true)])
    }

    private func send(type: String, for s: Session, extra: [String: JSONValue] = [:]) {
        var payload: [String: JSONValue] = ["sessionId": .string(s.id)]
        payload.merge(extra) { $1 }
        let envelope = Envelope(
            type: type, senderId: IdentityKeyStore.shared.deviceId,
            recipientId: s.deviceId, payload: .object(payload)
        )
        try? s.transport.send(envelope: envelope)
    }

    // MARK: - Bridge connection

    private func connect(_ s: Session, host: String, port: UInt16, token: String) {
        NSLog("Gossip: connecting to screen bridge ws://\(host):\(port)")
        guard let client = ScreenBridgeClient(host: host, port: port, token: token) else {
            return fail(s, "The phone sent an invalid screen-mirroring port.")
        }
        s.client = client
        var feeder: H264SampleFeeder?
        var audioPlayer: ScreenAudioPlayer?
        client.onEvent = { [weak self, weak s, weak client] event in
            switch event {
            case .header(let header):
                guard header.codec == "h264" else {
                    DispatchQueue.main.async { if let s { self?.fail(s, "Unsupported video codec \(header.codec).") } }
                    return
                }
                // The feeder is used on the client's queue from here on; the window is built on main.
                DispatchQueue.main.sync {
                    guard let self, let s, self.session === s else { return }
                    let window = ScreenMirrorWindow(
                        deviceName: header.deviceName.isEmpty ? s.deviceName : header.deviceName,
                        videoSize: CGSize(width: header.width, height: header.height)
                    )
                    window.sendControl = { [weak client] data in client?.sendControl(data) }
                    window.onClose = { [weak self, weak s] in
                        guard let self, let s, self.session === s else { return }
                        s.window = nil // already closing
                        self.stop()
                    }
                    s.window = window
                    let f = H264SampleFeeder(layer: window.content.displayLayer)
                    f.onNeedsKeyFrame = { [weak client] in client?.sendControl(ScrcpyControl.resetVideo) }
                    feeder = f
                    if let audio = header.audio {
                        audioPlayer = ScreenAudioPlayer(sampleRate: audio.sampleRate, channels: audio.channels)
                        s.audioPlayer = audioPlayer
                    }
                    s.retryTimer?.invalidate(); s.retryTimer = nil
                    self.state = .mirroring
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                }
            case .message(.video(let flags, let payload)):
                feeder?.handle(flags: flags, payload: payload)
            case .message(.size(let w, let h)):
                DispatchQueue.main.async { s?.window?.updateVideoSize(CGSize(width: w, height: h)) }
            case .message(.audio(let pcm)):
                audioPlayer?.enqueue(pcm: pcm)
            case .message(.deviceMessage):
                break
            case .closed(let error):
                DispatchQueue.main.async {
                    guard let self, let s, self.session === s else { return }
                    if self.state == .mirroring {
                        self.teardown(s) // phone ended the session or the link dropped
                    } else {
                        self.fail(s, "Couldn't connect to \(s.deviceName)'s screen stream\(error.map { " (\($0.localizedDescription))" } ?? "").")
                    }
                }
            }
        }
        client.connect()
    }

    // MARK: - Teardown

    private func fail(_ s: Session, _ message: String) {
        gossipError("Gossip: screen mirroring failed: \(message)")
        send(type: "screen.stop", for: s)
        teardown(s)
        lastError = message
    }

    private func teardown(_ s: Session) {
        guard session === s else { return }
        session = nil
        s.retryTimer?.invalidate()
        s.client?.close()
        s.audioPlayer?.stop()
        if let window = s.window {
            window.onClose = nil
            window.close()
        }
        state = .idle
        mirroringDeviceId = nil
    }
}
