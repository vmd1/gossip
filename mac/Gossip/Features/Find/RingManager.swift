import Foundation
import AppKit
import SwiftUI
import Combine
import GossipCoreKit

/// Plays and stops the actual alarm — behind a protocol so `RingManager`'s dedupe / auto-stop
/// logic is testable without making noise.
protocol Ringer: AnyObject {
    func start()
    func stop()
}

/// Handles `device.ring` (see `schema/message-types.md`) on the Mac: a paired device asks this Mac to ring at full volume so
/// it can be found, or to stop. One-shot trigger, so no resync loop, and idempotent: `start` while already ringing is a
/// no-op, `stop` while silent is a no-op, and a duplicate/late `start` (identified by its per-attempt `ringId`, kept in a
/// bounded recently-handled cache) can never restart a ring the user already stopped. Rings stop on their own after 30 s.
///
/// Whenever this Mac starts or stops ringing — a `stop` message, the auto-stop, or the local Stop window — it reports
/// `device.ring_state` back to whoever started the ring, so that device's ring button can show "ringing" and clear again.
///
/// Also the sending half: `toggleRing(deviceId)` for the ring button — starts a ring, or stops it if that peer is already
/// ringing — tracked in `ringingPeers`; a peer's entry also expires after 35 s as the self-healing backstop if a
/// `ring_state` report is ever lost.
///
/// All of that decision logic is the core's `Ring` (`desktop/core/src/features/ring.rs`), shared with every platform; this
/// class plays the alarm, shows the window and drives the core's clock once a second.
final class RingManager: ObservableObject {
    @Published private(set) var isRinging = false
    /// Peers this Mac has asked to ring that haven't reported stopping (or expired).
    @Published private(set) var ringingPeers: Set<String> = []

    private weak var transportManager: TransportManager?
    private let identity: IdentityKeyStore
    private let ringer: Ringer
    private let logic = GossipCoreKit.Ring()
    private let now: () -> Int64
    private let sendOverride: ((Envelope) -> Void)?
    private var timer: Timer?
    /// Shown while ringing so the user can silence it from the Mac itself.
    private var alertWindow: NSWindow?
    private let showsAlert: Bool

    init(transportManager: TransportManager, identity: IdentityKeyStore = .shared,
         ringer: Ringer = SystemAlarmRinger(), showsAlert: Bool = true,
         now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
         runsClock: Bool = true,
         sendEnvelope: ((Envelope) -> Void)? = nil) {
        self.sendOverride = sendEnvelope
        self.transportManager = transportManager
        self.identity = identity
        self.ringer = ringer
        self.showsAlert = showsAlert
        self.now = now
        transportManager.router.register(prefix: "device.ring") { [weak self] envelope in
            DispatchQueue.main.async { self?.handle(envelope) }
        }
        transportManager.router.register(prefix: "device.ring_state") { [weak self] envelope in
            DispatchQueue.main.async { self?.handleRingState(envelope) }
        }
        if runsClock {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    deinit { timer?.invalidate() }

    /// Main-thread only.
    func handle(_ envelope: Envelope) {
        guard let json = try? JSONEncoder().encode(envelope.payload),
              let effects = try? logic.onRing(sender: envelope.senderId, payloadJson: String(decoding: json, as: UTF8.self), nowMs: now()) else { return }
        carryOut(effects)
    }

    /// Silences the ring (also wired to the alert window's Stop button). No-op when not ringing.
    func stopRinging() { carryOut(logic.stopRinging()) }

    /// Auto-stop and peer-entry expiry; driven once a second (and directly by tests).
    func tick() { carryOut(logic.tick(nowMs: now())) }

    // MARK: - Sending

    /// Presses the ring button for `deviceId`: stops it if it's ringing, otherwise starts a ring. Main-thread only.
    func toggleRing(_ deviceId: String) {
        carryOut(logic.toggle(peer: deviceId, ringId: UUID().uuidString, nowMs: now()))
    }

    /// Main-thread only.
    func handleRingState(_ envelope: Envelope) {
        guard let json = try? JSONEncoder().encode(envelope.payload),
              let effects = try? logic.onRingState(sender: envelope.senderId, payloadJson: String(decoding: json, as: UTF8.self), nowMs: now()) else { return }
        carryOut(effects)
    }

    private func carryOut(_ effects: [GossipCoreKit.RingEffect]) {
        for effect in effects {
            switch effect {
            case .startRinger: ringer.start()
            case .stopRinger: ringer.stop()
            case .showAlert: if showsAlert { showAlert() }
            case .closeAlert: alertWindow?.close(); alertWindow = nil
            case .send(let message): send(message)
            case .peersChanged: break
            }
        }
        isRinging = logic.isRinging()
        let peers = Set(logic.ringingPeers())
        if peers != ringingPeers { ringingPeers = peers }
    }

    private func send(_ message: GossipCoreKit.Outgoing) {
        guard let payload = try? JSONDecoder().decode(JSONValue.self, from: Data(message.payloadJson.utf8)) else { return }
        let envelope = Envelope(type: message.kind, senderId: identity.deviceId, recipientId: message.recipient, payload: payload)
        if let sendOverride { sendOverride(envelope) } else { try? transportManager?.send(envelope: envelope) }
    }

    private func showAlert() {
        let view = VStack(spacing: 12) {
            Image(systemName: "bell.and.waves.left.and.right.fill").font(.system(size: 32))
            Text("Gossip is ringing this Mac").font(.headline)
            Text("A paired device asked this Mac to ring.").foregroundStyle(.secondary)
            Button("Stop") { [weak self] in self?.stopRinging() }.keyboardShortcut(.defaultAction)
        }.padding(24).frame(width: 300)
        let window = NSPanel(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .utilityWindow]
        window.title = "Find my device"
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        alertWindow = window
    }
}

/// Loops a system alert sound at maximum output volume (unmuting if needed), restoring the
/// previous volume/mute state afterwards.
final class SystemAlarmRinger: Ringer {
    private var sound: NSSound?
    private var saved: (volume: Int, muted: Bool)?

    func start() {
        guard sound == nil else { return }
        if let state = Self.runAppleScript("(output volume of (get volume settings)) & \",\" & (output muted of (get volume settings))")?
            .split(separator: ",").map({ String($0) }), state.count == 2, let v = Int(state[0]) {
            saved = (v, state[1] == "true")
        }
        _ = Self.runAppleScript("set volume without output muted output volume 100")
        let s = NSSound(named: "Sosumi") ?? NSSound(named: "Funk")
        s?.loops = true
        s?.play()
        sound = s
    }

    func stop() {
        sound?.stop(); sound = nil
        if let saved {
            _ = Self.runAppleScript("set volume output volume \(saved.volume)" + (saved.muted ? " with output muted" : " without output muted"))
        }
        saved = nil
    }

    private static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
    }
}
