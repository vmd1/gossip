import AppKit
import Combine

/// Bidirectional plain-text clipboard sync between this Mac and its paired peer.
///
/// `NSPasteboard` has no push/change-notification API, so this manager polls
/// `NSPasteboard.general.changeCount` on a timer while the transport is connected.
/// On a genuine local copy it sends a `clipboard.update` envelope; on a received
/// `clipboard.update` it writes the text into the local pasteboard.
///
/// Loop suppression: writing to the pasteboard ourselves (in response to a remote
/// update) bumps `changeCount` exactly like a real local copy would, which would
/// otherwise be observed by the very next poll and re-sent right back to the
/// sender. To avoid that, we remember the last value *we* wrote programmatically
/// and skip sending when the newly-observed pasteboard text matches it exactly.
final class ClipboardSyncManager: ObservableObject {
    private let transportManager: TransportManager
    private let identity: IdentityKeyStore
    private let pollInterval: TimeInterval

    private var timer: Timer?
    private var lastChangeCount: Int
    private var lastRemoteSetValue: String?

    init(
        transportManager: TransportManager,
        identity: IdentityKeyStore = .shared,
        pollInterval: TimeInterval = 0.5
    ) {
        self.transportManager = transportManager
        self.identity = identity
        self.pollInterval = pollInterval
        self.lastChangeCount = NSPasteboard.general.changeCount

        transportManager.router.register(prefix: "clipboard.update") { [weak self] envelope in
            self?.handleIncoming(envelope)
        }
    }

    // MARK: - Lifecycle

    /// Starts polling the pasteboard. Call when the transport becomes connected.
    func start() {
        stop()
        lastChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.pollPasteboard()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stops polling. Call when the transport disconnects.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Outbound: local pasteboard -> wire

    private func pollPasteboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        guard let text = pasteboard.string(forType: .string) else { return }
        guard Self.shouldSend(newValue: text, lastRemoteSetValue: lastRemoteSetValue) else { return }

        sendClipboardUpdate(text: text)
    }

    private func sendClipboardUpdate(text: String) {
        let envelope = Envelope(
            type: "clipboard.update",
            senderId: identity.deviceId,
            broadcast: true,
            payload: .object([
                "text": .string(text),
                "sourceDeviceId": .string(identity.deviceId),
            ])
        )
        try? transportManager.send(envelope: envelope)
    }

    // MARK: - Inbound: wire -> local pasteboard

    private func handleIncoming(_ envelope: Envelope) {
        guard let text = envelope.payload["text"]?.stringValue else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Record both what we wrote and the resulting changeCount so our own
        // poll doesn't treat this as a new local copy and echo it back.
        lastChangeCount = pasteboard.changeCount
        lastRemoteSetValue = text
    }

    // MARK: - Loop-suppression (pure, unit-testable)

    /// Returns whether a newly-observed pasteboard value should be sent over the
    /// wire, given the last value this manager itself wrote to the pasteboard in
    /// response to a remote update. Returns `false` when `newValue` is exactly
    /// that echoed value (suppressing the infinite-ping-pong loop), `true`
    /// otherwise (a genuine local copy, or the very first observation).
    static func shouldSend(newValue: String, lastRemoteSetValue: String?) -> Bool {
        newValue != lastRemoteSetValue
    }
}
