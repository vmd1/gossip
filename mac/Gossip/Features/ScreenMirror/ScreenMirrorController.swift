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
///
/// Several sessions can run at once: one whole-screen mirror (what `state` / `mirroringDeviceId` describe, driving the
/// menu's mirror button) plus any number of app windows (`screen.start` with an `app`), each its own session and window.
/// Resizing an app window re-creates its virtual display at the new size (`resize`).
final class ScreenMirrorController: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case mirroring
    }

    /// The whole-screen mirror's state (app windows don't change it).
    @Published private(set) var state: State = .idle

    /// Which trusted device (by Gossip `deviceId`) the whole-screen mirror targets, so the menu can show
    /// "Stop Mirroring" on the right row.
    @Published private(set) var mirroringDeviceId: String?

    /// A launchable app on a phone (`screen.apps`), for "Open App Window".
    struct PhoneApp: Identifiable, Equatable {
        let package: String
        let label: String
        var id: String { package }
    }

    /// Apps each phone reported for `screen.apps_request`, keyed by device id; `appsError` is a user-facing reason a list couldn't be had.
    @Published private(set) var appsByDevice: [String: [PhoneApp]] = [:]
    @Published private(set) var appsError: [String: String] = [:]
    /// App icons by package, per device, filled in by `screen.app_icons` batches (a merge, so repeats change nothing).
    @Published private(set) var iconsByDevice: [String: [String: NSImage]] = [:]

    /// Asks `deviceId` for the apps it can open as windows, with their icons. A pure query: asking again just gets a fresh answer.
    func requestApps(deviceId: String, transport: TransportManager) {
        registerRouterIfNeeded(transport)
        let envelope = Envelope(
            type: "screen.apps_request", senderId: IdentityKeyStore.shared.deviceId,
            recipientId: deviceId, ttl: 0, payload: .object(["icons": .bool(true)])
        )
        try? transport.send(envelope: envelope)
    }

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
    /// The phone runs at most this many app windows at once (`ScreenMirrorState.MAX_APP_WINDOWS`).
    static let maxAppWindows = 4

    private final class Session {
        let id = UUID().uuidString
        let deviceId: String
        let deviceName: String
        let transport: TransportManager
        let startedAt = Date()
        /// Package of the app this session opens as its own window, or `nil` when mirroring the whole screen.
        var app: String?
        var appLabel: String?
        /// Virtual display size requested for an app window (`WxH`), in the phone's pixels.
        var appSize: CGSize?
        var retryTimer: Timer?
        var client: ScreenBridgeClient?
        var window: ScreenMirrorWindow?
        var audioPlayer: ScreenAudioPlayer?
        /// A resized window re-uses the previous session's window; `nil` for a first start.
        var inheritedWindow: ScreenMirrorWindow?
        var isApp: Bool { app != nil }
        init(deviceId: String, deviceName: String, transport: TransportManager) {
            self.deviceId = deviceId; self.deviceName = deviceName; self.transport = transport
        }
    }

    private var sessions: [String: Session] = [:]
    private var routerRegistered = false
    private var resizeWork: [String: DispatchWorkItem] = [:]

    private var fullSession: Session? { sessions.values.first { !$0.isApp } }

    /// App windows currently open (or opening).
    var openAppWindowCount: Int { sessions.values.filter(\.isApp).count }

    /// Starts mirroring `deviceId`'s whole screen, or opens `app` as its own window. Must be called on the main thread.
    /// The device must currently be connected over the mesh (the session is negotiated there and the viewer dials the
    /// address the mesh connection came from).
    func start(deviceId: String, deviceName: String, transport: TransportManager, app: PhoneApp? = nil) {
        if app == nil, fullSession != nil { return } // one whole-screen mirror at a time
        lastError = nil
        guard FeatureSettings.shared.isEnabled(.screenMirroring) else {
            lastError = "Screen mirroring is turned off in Settings."
            return
        }
        guard !transport.isRelayed(deviceId) else {
            lastError = "\(deviceName) is connected through the relay. Screen mirroring needs both devices on the same network."
            return
        }
        guard transport.hostWithZone(for: deviceId) != nil else {
            lastError = "\(deviceName) isn't connected right now."
            return
        }
        if let app, sessions.values.contains(where: { $0.deviceId == deviceId && $0.app == app.package }) {
            // Already open: bring its window forward instead of starting a second copy.
            sessions.values.first { $0.deviceId == deviceId && $0.app == app.package }?.window?.makeKeyAndOrderFront(nil)
            return
        }
        if app != nil, openAppWindowCount >= Self.maxAppWindows {
            lastError = "\(Self.maxAppWindows) app windows are already open. Close one to open another."
            return
        }
        let s = Session(deviceId: deviceId, deviceName: deviceName, transport: transport)
        s.app = app?.package
        s.appLabel = app?.label
        begin(s)
    }

    private func begin(_ s: Session) {
        registerRouterIfNeeded(s.transport)
        sessions[s.id] = s
        if !s.isApp { state = .starting; mirroringDeviceId = s.deviceId }
        sendStart(s)
        s.retryTimer = Timer.scheduledTimer(withTimeInterval: Self.retryInterval, repeats: true) { [weak self, weak s] timer in
            guard let self, let s, self.sessions[s.id] === s else { return timer.invalidate() }
            if Date().timeIntervalSince(s.startedAt) > Self.readyTimeout {
                self.fail(s, s.isApp
                    ? "\(s.appLabel ?? "The app") didn't open on \(s.deviceName). It may be disabled or put to sleep on the phone (Samsung: Battery → Background usage limits)."
                    : "\(s.deviceName) didn't respond. Is Gossip updated on the phone?")
            } else {
                self.sendStart(s)
            }
        }
    }

    /// Ends the whole-screen mirror (menu "Stop Mirroring" or window closed). Idempotent.
    func stop() {
        guard let s = fullSession else { return }
        send(type: "screen.stop", for: s)
        teardown(s)
    }

    /// Ends every session, app windows included.
    func stopAll() {
        for s in Array(sessions.values) { send(type: "screen.stop", for: s); teardown(s) }
    }

    // MARK: - Resizing app windows

    /// An app window was resized: after a short pause, re-create its virtual display at the new size. The app is stopped
    /// and re-launched on the new display (Android can't resize a virtual display in place), so it briefly reloads.
    private func resize(_ s: Session, to contentSize: CGSize) {
        resizeWork[s.id]?.cancel()
        let work = DispatchWorkItem { [weak self, weak s] in
            guard let self, let s, self.sessions[s.id] === s, s.isApp else { return }
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            func even(_ v: CGFloat) -> CGFloat { (max(320, min(2560, v * scale)) / 2).rounded(.down) * 2 }
            let size = CGSize(width: even(contentSize.width), height: even(contentSize.height))
            if let current = s.appSize, abs(current.width - size.width) < 24, abs(current.height - size.height) < 24 { return }
            let replacement = Session(deviceId: s.deviceId, deviceName: s.deviceName, transport: s.transport)
            replacement.app = s.app; replacement.appLabel = s.appLabel; replacement.appSize = size
            replacement.inheritedWindow = s.window
            // Stop the old display first so the app isn't running on two displays at once, then start the new one.
            self.send(type: "screen.stop", for: s)
            self.teardown(s, keepWindow: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.begin(replacement) }
        }
        resizeWork[s.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
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
        switch envelope.type {
        case "screen.apps":
            let apps: [PhoneApp] = envelope.payload["apps"]?.arrayValue?.compactMap { item in
                guard let pkg = item["package"]?.stringValue, let label = item["label"]?.stringValue else { return nil }
                return PhoneApp(package: pkg, label: label)
            } ?? []
            appsByDevice[envelope.senderId] = apps
            appsError[envelope.senderId] = envelope.payload["reason"]?.stringValue == "feature_disabled"
                ? "Screen mirroring is turned off on that device." : nil
            return
        case "screen.app_icons":
            var table = iconsByDevice[envelope.senderId] ?? [:]
            for item in envelope.payload["icons"]?.arrayValue ?? [] {
                guard let pkg = item["package"]?.stringValue, let b64 = item["png"]?.stringValue,
                      let data = Data(base64Encoded: b64), data.count < 64 * 1024, let image = NSImage(data: data) else { continue }
                table[pkg] = image
            }
            iconsByDevice[envelope.senderId] = table
            return
        default:
            break
        }
        guard let id = envelope.payload["sessionId"]?.stringValue, let s = sessions[id], envelope.senderId == s.deviceId else {
            NSLog("Gossip: ignoring \(envelope.type) (unknown session or sender \(envelope.senderId))")
            return
        }
        NSLog("Gossip: received \(envelope.type) for session \(s.id)")
        switch envelope.type {
        case "screen.ready":
            // Idempotent: the phone re-sends `screen.ready` for every duplicate start we send.
            guard s.client == nil,
                  let port = envelope.payload["port"]?.numberValue,
                  let secretBase64 = envelope.payload["secret"]?.stringValue,
                  let secret = Data(base64Encoded: secretBase64), secret.count == 32,
                  let host = s.transport.hostWithZone(for: s.deviceId) else { return }
            connect(s, host: host, port: UInt16(clamping: Int(port)), secret: secret)
        case "screen.error":
            let reason = envelope.payload["reason"]?.stringValue ?? "unknown"
            fail(s, Self.message(forErrorReason: reason, deviceName: s.deviceName, app: s.appLabel))
        default:
            break
        }
    }

    private static func message(forErrorReason reason: String, deviceName: String, app: String?) -> String {
        switch reason {
        case "shizuku_unavailable":
            return "Shizuku isn't running on \(deviceName). Start it (it needs re-activating after every reboot) and allow Gossip."
        case "feature_disabled":
            return "Screen mirroring is turned off on \(deviceName). Turn it on in Gossip's settings there."
        case "capture_failed":
            return "\(deviceName) couldn't start screen capture. Check Shizuku and try again."
        case "app_disabled":
            return "\(app ?? "That app") is disabled on \(deviceName), so it can't be opened. Enable it in Android's app settings."
        case "app_unavailable":
            return "\(app ?? "That app") can't be opened on \(deviceName) (it was uninstalled or has no launcher)."
        default:
            return "\(deviceName) couldn't start mirroring (\(reason))."
        }
    }

    private func sendStart(_ s: Session) {
        var extra: [String: JSONValue] = ["maxSize": .number(1600), "bitRate": .number(8_000_000), "maxFps": .number(60), "audio": .bool(true)]
        if let app = s.app { // an app window on a virtual display instead of the whole screen
            extra["app"] = .string(app)
            if let size = s.appSize { extra["appSize"] = .string("\(Int(size.width))x\(Int(size.height))") }
            extra["maxSize"] = .number(2560) // the virtual display is already sized to the window
        }
        send(type: "screen.start", for: s, extra: extra)
    }

    private func send(type: String, for s: Session, extra: [String: JSONValue] = [:]) {
        var payload: [String: JSONValue] = ["sessionId": .string(s.id)]
        payload.merge(extra) { $1 }
        let envelope = Envelope(
            type: type, senderId: IdentityKeyStore.shared.deviceId,
            recipientId: s.deviceId, ttl: 0, payload: .object(payload)
        )
        try? s.transport.send(envelope: envelope)
    }

    // MARK: - Bridge connection

    private func connect(_ s: Session, host: String, port: UInt16, secret: Data) {
        NSLog("Gossip: connecting to screen bridge ws://\(host):\(port)")
        guard let client = ScreenBridgeClient(host: host, port: port, secret: secret, sessionId: s.id) else {
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
                    guard let self, let s, self.sessions[s.id] === s else { return }
                    let window: ScreenMirrorWindow
                    if let inherited = s.inheritedWindow {
                        window = inherited // a resize: same window, new stream
                        window.content.displayLayer.flushAndRemoveImage()
                        window.content.videoSize = CGSize(width: header.width, height: header.height)
                    } else {
                        window = ScreenMirrorWindow(
                            deviceName: s.appLabel ?? (header.deviceName.isEmpty ? s.deviceName : header.deviceName),
                            videoSize: CGSize(width: header.width, height: header.height),
                            freeResize: s.isApp
                        )
                        window.onClose = { [weak self, weak s] in
                            guard let self, let s, self.sessions[s.id] === s else { return }
                            s.window = nil // already closing
                            self.send(type: "screen.stop", for: s)
                            self.teardown(s)
                        }
                    }
                    s.appSize = s.appSize ?? CGSize(width: header.width, height: header.height)
                    window.sendControl = { [weak client] data in client?.sendControl(data) }
                    window.onResizeEnd = { [weak self, weak s] size in
                        if let self, let s { self.resize(s, to: size) }
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
                    if !s.isApp { self.state = .mirroring }
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
                    guard let self, let s, self.sessions[s.id] === s else { return }
                    if s.window != nil {
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

    private func teardown(_ s: Session, keepWindow: Bool = false) {
        guard sessions[s.id] === s else { return }
        sessions[s.id] = nil
        resizeWork[s.id]?.cancel(); resizeWork[s.id] = nil
        s.retryTimer?.invalidate()
        s.client?.close()
        s.audioPlayer?.stop()
        if !keepWindow, let window = s.window ?? s.inheritedWindow {
            window.onClose = nil
            window.close()
        } else if keepWindow {
            s.window?.sendControl = nil
        }
        if !s.isApp {
            state = .idle
            mirroringDeviceId = nil
        }
    }
}
