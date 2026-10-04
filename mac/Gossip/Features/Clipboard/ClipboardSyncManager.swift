import AppKit
import ImageIO
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
    private var resyncTimer: Timer?
    private var lastChangeCount: Int
    private var lastRemoteSetValue: String?
    private var lastRemoteSetImageData: Data?

    /// The last value *this Mac itself* successfully sent (as opposed to
    /// `lastRemoteSetValue`, which is the last value *received* from a peer). Without
    /// this, the periodic resync in `sendCurrentPasteboardContentIfNeeded` would
    /// re-broadcast a locally-originated pasteboard value on every tick forever —
    /// `lastRemoteSetValue` alone never matches it, since that's only ever set by
    /// `handleIncoming`/`handleIncomingImage`.
    private var lastSentValue: String?
    private var lastSentImageData: Data?

    /// Periodic-resync interval — matches `dnd.update`/`trust.roster_update`/
    /// `lock_on_leave.config`'s existing ~60s self-healing cadence.
    private static let resyncInterval: TimeInterval = 60

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
    ///
    /// Also resends whatever is currently on the pasteboard once, immediately — per
    /// this project's `CLAUDE.md` convention that anything configuring state on a
    /// recipient needs a self-healing resync, not just a one-shot send-on-change.
    /// Without this, a local copy made *while transiently disconnected* (or lost to
    /// any other send race) would never reach a peer until the next actual clipboard
    /// change on this Mac, which might be a long time or never — the exact same
    /// silent-desync failure mode `dnd.update`'s `isInitialSync` and
    /// `lock_on_leave.config`'s on-connect resend both exist to prevent. Goes through
    /// the same `shouldSend` loop-guard as a real poll, so it's a no-op on a peer that
    /// already has this exact value (e.g. multiple peers reconnecting around the same
    /// time doesn't cause a resend storm beyond one message per newly-live peer).
    func start() {
        stop()
        lastChangeCount = NSPasteboard.general.changeCount
        sendCurrentPasteboardContentIfNeeded()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.pollPasteboard()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // Periodic backstop on top of the on-connect resync above and the frequent
        // change-detecting poll — covers a `clipboard.update` send that was attempted
        // mid-disconnect or otherwise dropped, which neither of those catches (the
        // poll only reacts to a *new* local change; a drop leaves both sides silently
        // mismatched until the next one). Harmless when already in sync: goes through
        // the same loop-guarded send path as a real poll.
        let resync = Timer(timeInterval: Self.resyncInterval, repeats: true) { [weak self] _ in
            self?.sendCurrentPasteboardContentIfNeeded()
        }
        RunLoop.main.add(resync, forMode: .common)
        self.resyncTimer = resync
    }

    /// Stops polling. Call when the transport disconnects.
    func stop() {
        timer?.invalidate()
        timer = nil
        resyncTimer?.invalidate()
        resyncTimer = nil
    }

    // MARK: - Outbound: local pasteboard -> wire

    private func pollPasteboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount // also while disabled, so re-enabling doesn't send a stale copy
        guard FeatureSettings.shared.isEnabled(.clipboard) else { return }
        sendCurrentPasteboardContentIfNeeded()
    }

    /// Sends whatever is currently on the pasteboard (if anything, and if it isn't
    /// just the echo of a remote update we wrote ourselves), regardless of whether
    /// `changeCount` moved — the shared body behind both a real detected change
    /// (`pollPasteboard`) and the on-connect resync (`start`).
    private func sendCurrentPasteboardContentIfNeeded() {
        let pasteboard = NSPasteboard.general

        // Never broadcast what the copying app marked as a secret (password managers) or transient.
        guard !Self.isSensitive(types: pasteboard.types) else { return }

        // Text takes priority when both are somehow present, matching pre-image
        // behavior exactly for plain-text copies.
        if let text = pasteboard.string(forType: .string) {
            guard Self.textAllowed(text) else { return }
            guard Self.shouldSend(newValue: text, lastRemoteSetValue: lastRemoteSetValue, lastSentValue: lastSentValue) else { return }
            sendClipboardUpdate(text: text)
            return
        }

        guard let pngData = Self.imagePNGData(from: pasteboard), Self.imageBytesAllowed(pngData.count) else { return }
        guard Self.shouldSend(newImageData: pngData, lastRemoteSetImageData: lastRemoteSetImageData, lastSentImageData: lastSentImageData) else { return }
        sendClipboardImage(data: pngData)
    }

    private func sendClipboardUpdate(text: String) {
        lastSentValue = text
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
        lastSentImageData = data
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
        guard let text = envelope.payload["text"]?.stringValue, Self.textAllowed(text) else { return }

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
              envelope.payload["kind"]?.stringValue == "image",
              Self.imageBytesAllowed(data.count), Self.isReasonableImage(data) else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)

        lastChangeCount = pasteboard.changeCount
        lastRemoteSetImageData = data
    }

    // MARK: - Content policy (pure, unit-testable)

    static let maxTextBytes = 1 << 20
    static let maxImageBytes = 8 << 20
    static let maxImagePixels = 40_000_000

    /// Pasteboard types the nspasteboard.org convention uses to mark content that must not be stored
    /// or synced: concealed (passwords), transient, auto-generated; plus 1Password's own marker.
    static let sensitiveTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword",
    ]

    static func isSensitive(types: [NSPasteboard.PasteboardType]?) -> Bool {
        (types ?? []).contains { sensitiveTypes.contains($0.rawValue) }
    }

    static func textAllowed(_ text: String) -> Bool { text.utf8.count <= maxTextBytes }

    static func imageBytesAllowed(_ count: Int) -> Bool { count > 0 && count <= maxImageBytes }

    /// Reads just the header: refuses data that isn't an image or whose decoded size is a decompression bomb.
    static func isReasonableImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return false }
        return w * h <= maxImagePixels
    }

    // MARK: - Loop-suppression (pure, unit-testable)

    /// Returns whether a newly-observed pasteboard value should be sent over the
    /// wire, given the last value this manager itself wrote to the pasteboard in
    /// response to a remote update (`lastRemoteSetValue`) and the last value this
    /// manager itself already sent (`lastSentValue`). Returns `false` when `newValue`
    /// matches either (an echoed remote update, or a value the periodic resync would
    /// otherwise re-broadcast forever since `lastRemoteSetValue` alone never catches a
    /// locally-originated value), `true` otherwise (a genuine local copy, or the very
    /// first observation).
    static func shouldSend(newValue: String, lastRemoteSetValue: String?, lastSentValue: String? = nil) -> Bool {
        newValue != lastRemoteSetValue && newValue != lastSentValue
    }

    /// Same loop-suppression check as `shouldSend(newValue:lastRemoteSetValue:lastSentValue:)`,
    /// for image content.
    static func shouldSend(newImageData: Data, lastRemoteSetImageData: Data?, lastSentImageData: Data? = nil) -> Bool {
        newImageData != lastRemoteSetImageData && newImageData != lastSentImageData
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
