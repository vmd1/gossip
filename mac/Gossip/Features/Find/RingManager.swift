import Foundation
import AppKit
import SwiftUI
import Combine

/// Plays and stops the actual alarm — behind a protocol so `RingManager`'s dedupe / auto-stop
/// logic is testable without making noise.
protocol Ringer: AnyObject {
    func start()
    func stop()
}

/// Handles `device.ring` (see `schema/message-types.md`) on the Mac: a paired device asks this
/// Mac to ring at full volume so it can be found, or to stop. One-shot trigger, so no resync loop,
/// but idempotent: `start` while already ringing is a no-op, `stop` while silent is a no-op, and a
/// duplicate/late `start` (identified by its per-attempt `ringId`, kept in a bounded
/// recently-handled cache like `media.command`'s `commandId`) can never restart a ring the user
/// already stopped. Rings stop on their own after `autoStopInterval`.
///
/// Also the sending half: `sendRing(to:start:)` for the Mac menu's "Ring" button.
final class RingManager: ObservableObject {
    static let autoStopInterval: TimeInterval = 30
    private static let recentCacheSize = 64

    @Published private(set) var isRinging = false

    private weak var transportManager: TransportManager?
    private let identity: IdentityKeyStore
    private let ringer: Ringer
    private let autoStopAfter: TimeInterval
    private var recentRingIds: [String] = []
    private var autoStop: DispatchWorkItem?
    /// Shown while ringing so the user can silence it from the Mac itself.
    private var alertWindow: NSWindow?
    private let showsAlert: Bool

    init(transportManager: TransportManager, identity: IdentityKeyStore = .shared,
         ringer: Ringer = SystemAlarmRinger(), autoStopAfter: TimeInterval = RingManager.autoStopInterval,
         showsAlert: Bool = true) {
        self.transportManager = transportManager
        self.identity = identity
        self.ringer = ringer
        self.autoStopAfter = autoStopAfter
        self.showsAlert = showsAlert
        transportManager.router.register(prefix: "device.ring") { [weak self] envelope in
            DispatchQueue.main.async { self?.handle(envelope) }
        }
    }

    /// Main-thread only.
    func handle(_ envelope: Envelope) {
        guard let action = envelope.payload["action"]?.stringValue,
              let ringId = envelope.payload["ringId"]?.stringValue else { return }
        switch action {
        case "start":
            if recentRingIds.contains(ringId) { return }  // duplicate / late redelivery
            recentRingIds.append(ringId)
            if recentRingIds.count > Self.recentCacheSize { recentRingIds.removeFirst() }
            guard !isRinging else { return }
            isRinging = true
            ringer.start()
            if showsAlert { showAlert() }
            let work = DispatchWorkItem { [weak self] in self?.stopRinging() }
            autoStop = work
            DispatchQueue.main.asyncAfter(deadline: .now() + autoStopAfter, execute: work)
        case "stop":
            stopRinging()
        default:
            break
        }
    }

    /// Silences the ring (also wired to the alert window's Stop button). No-op when not ringing.
    func stopRinging() {
        autoStop?.cancel(); autoStop = nil
        guard isRinging else { return }
        isRinging = false
        ringer.stop()
        alertWindow?.close(); alertWindow = nil
    }

    // MARK: - Sending

    static func payload(action: String, ringId: String = UUID().uuidString) -> JSONValue {
        .object(["action": .string(action), "ringId": .string(ringId)])
    }

    func sendRing(to deviceId: String, start: Bool) {
        let envelope = Envelope(type: "device.ring", senderId: identity.deviceId, recipientId: deviceId,
                                payload: Self.payload(action: start ? "start" : "stop"))
        try? transportManager?.send(envelope: envelope)
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
