import AppKit
import Combine

/// Bidirectional clipboard sync between this Mac and the rest of the mesh — plain text
/// (broadcast, relayed through the whole mesh like any other message) and images
/// (broadcast too, but the actual bytes travel as a raw follow-up frame per
/// `docs/wire-protocol.md`'s "Large binary payloads" convention, relayed hop-by-hop
/// alongside their metadata envelope — see `TransportManager.handleReceivedEnvelope`).
///
/// `NSPasteboard` has no push/change-notification API, so this manager polls
/// `NSPasteboard.general.changeCount` on a timer while the transport is connected. On a
/// genuine local copy it sends a `clipboard.update` envelope (text inline, or an image
/// normalized to PNG and sent as a raw follow-up frame); on a received `clipboard.update`
/// it writes the content into the local pasteboard.
///
/// Loop suppression: writing to the pasteboard ourselves (in response to a remote
/// update) bumps `changeCount` exactly like a real local copy would, which would
/// otherwise be observed by the very next poll and re-sent right back to the
/// sender. To avoid that, we remember the last value *we* wrote programmatically
/// (text or image, whichever) and skip sending when the newly-observed pasteboard
/// content matches it exactly.
final class ClipboardSyncManager: ObservableObject {
    private let transportManager: TransportManager
    private let identity: IdentityKeyStore
    private let pollInterval: TimeInterval

    private var timer: Timer?
    private var lastChangeCount: Int
    private var lastRemoteSetValue: String?
    private var lastRemoteSetImageData: Data?

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
        transportManager.onRawFrameReceived = { [weak self] envelope, data in
            self?.handleIncomingImage(envelope, data)
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

        // Text takes priority when both are somehow present, matching pre-image
        // behavior exactly for plain-text copies.
        if let text = pasteboard.string(forType: .string) {
            guard Self.shouldSend(newValue: text, lastRemoteSetValue: lastRemoteSetValue) else { return }
            sendClipboardUpdate(text: text)
            return
        }

        guard let pngData = Self.imagePNGData(from: pasteboard) else { return }
        guard Self.shouldSend(newImageData: pngData, lastRemoteSetImageData: lastRemoteSetImageData) else { return }
        sendClipboardImage(data: pngData)
    }

    private func sendClipboardUpdate(text: String) {
        let envelope = Envelope(
            type: "clipboard.update",
            senderId: identity.deviceId,
            broadcast: true,
            payload: .object([
                "kind": .string("text"),
                "text": .string(text),
                "sourceDeviceId": .string(identity.deviceId),
            ])
        )
        try? transportManager.send(envelope: envelope)
    }

    private func sendClipboardImage(data: Data) {
        let envelope = Envelope(
            type: "clipboard.update",
            senderId: identity.deviceId,
            broadcast: true,
            hasRawFollowup: true,
            payload: .object([
                "kind": .string("image"),
                "sourceDeviceId": .string(identity.deviceId),
                "contentType": .string("image/png"),
                "byteLength": .number(Double(data.count)),
            ])
        )
        try? transportManager.send(envelope, withRawFollowup: data)
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

    private func handleIncomingImage(_ envelope: Envelope, _ data: Data) {
        guard envelope.type == "clipboard.update",
              envelope.payload["kind"]?.stringValue == "image" else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)

        lastChangeCount = pasteboard.changeCount
        lastRemoteSetImageData = data
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

    /// Same loop-suppression check as `shouldSend(newValue:lastRemoteSetValue:)`, for
    /// image content.
    static func shouldSend(newImageData: Data, lastRemoteSetImageData: Data?) -> Bool {
        newImageData != lastRemoteSetImageData
    }

    // MARK: - Image handling (pure enough to unit test the byte-level parts; pasteboard read is not)

    /// Reads whatever image is currently on the pasteboard (if any) and normalizes it
    /// to PNG — regardless of which representation the source app actually put there
    /// (TIFF is the one AppKit guarantees is always present for image content) — so
    /// the wire format is always a single, universally-decodable content type
    /// (`image/png`) rather than whatever the copying app happened to provide.
    static func imagePNGData(from pasteboard: NSPasteboard) -> Data? {
        guard pasteboard.canReadItem(withDataConformingToTypes: [NSPasteboard.PasteboardType.tiff.rawValue, NSPasteboard.PasteboardType.png.rawValue]) else {
            return nil
        }
        if let pngData = pasteboard.data(forType: .png) {
            return pngData
        }
        guard let tiffData = pasteboard.data(forType: .tiff),
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}
