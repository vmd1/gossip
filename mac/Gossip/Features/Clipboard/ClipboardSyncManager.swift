import AppKit
import Combine
import GossipCoreKit

/// Bidirectional clipboard sync between this Mac and the rest of the mesh: plain text, which travels as the
/// `clipboard.text` state slot (so the core keeps it correct across reconnects, see `docs/plans/state-sync.md`), and images,
/// which are `clipboard.update` messages whose bytes travel as a raw follow-up frame per `docs/wire-protocol.md`'s "Large
/// binary payloads" convention, relayed hop-by-hop alongside their metadata envelope.
///
/// `NSPasteboard` has no push/change-notification API, so this manager polls `NSPasteboard.general.changeCount` on a timer
/// while the transport is connected. On a genuine local copy it publishes the text slot (or sends an image normalized to
/// PNG); when a peer's text slot changes or an image arrives it writes the content into the local pasteboard.
///
/// The content policy and the loop suppression (writing the pasteboard ourselves in response to a peer bumps `changeCount`
/// exactly like a real copy, and must not be sent straight back) are the core's `ClipboardGuard`
/// (`desktop/core/src/features/clipboard.rs`), shared with every platform.
final class ClipboardSyncManager: ObservableObject {
    private let transportManager: TransportManager
    private let identity: IdentityKeyStore
    private let pollInterval: TimeInterval
    private let guardLogic = GossipCoreKit.ClipboardGuard()

    private var timer: Timer?
    private var lastChangeCount: Int

    init(
        transportManager: TransportManager,
        identity: IdentityKeyStore = .shared,
        pollInterval: TimeInterval = 0.5
    ) {
        self.transportManager = transportManager
        self.identity = identity
        self.pollInterval = pollInterval
        self.lastChangeCount = NSPasteboard.general.changeCount

        transportManager.addOnStateChanged { [weak self] change in
            guard change.slot == GossipCoreKit.clipboardTextSlot(), let json = change.valueJSON else { return }
            self?.handleIncomingText(valueJSON: json)
        }
        transportManager.onRawFrameReceived = { [weak self] envelope, data in
            self?.handleIncomingImage(envelope, data)
        }
    }

    /// Writes a history entry back to the pasteboard. Records the new `changeCount` so the poll doesn't treat it as a
    /// fresh copy; it is already in the history (and moves to the top via `record`).
    func copyFromHistory(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastChangeCount = pasteboard.changeCount
        ClipboardHistoryStore.shared.record(text, remote: false)
        if FeatureSettings.shared.isEnabled(.clipboard),
           let value = guardLogic.outgoingText(me: identity.deviceId, text: text, sensitive: false) {
            transportManager.setState(slot: GossipCoreKit.clipboardTextSlot(), valueJSON: value)
        }
    }

    // MARK: - Lifecycle

    /// Starts polling the pasteboard. Call when the transport becomes connected. Publishes whatever is on the pasteboard now
    /// (a copy made while disconnected is picked up here); the core ignores a value it already has.
    func start() {
        stop()
        lastChangeCount = NSPasteboard.general.changeCount
        sendCurrentPasteboardContentIfNeeded()
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
        lastChangeCount = pasteboard.changeCount // also while disabled, so re-enabling doesn't send a stale copy
        // The history is its own feature (device-local, own switch): it records every genuine local copy whether or not
        // clipboard sync is on, and whether or not the sync guard would suppress it as a repeat.
        recordLocalCopyInHistory()
        guard FeatureSettings.shared.isEnabled(.clipboard) else { return }
        sendCurrentPasteboardContentIfNeeded()
    }

    private func recordLocalCopyInHistory() {
        let pasteboard = NSPasteboard.general
        guard !Self.isSensitive(types: pasteboard.types), let text = pasteboard.string(forType: .string) else { return }
        ClipboardHistoryStore.shared.record(text, remote: false)
    }

    /// Publishes whatever is currently on the pasteboard (if anything, and if it isn't just the echo of a remote update we
    /// wrote ourselves), regardless of whether `changeCount` moved.
    private func sendCurrentPasteboardContentIfNeeded() {
        let pasteboard = NSPasteboard.general

        // Never broadcast what the copying app marked as a secret (password managers) or transient.
        let sensitive = Self.isSensitive(types: pasteboard.types)
        guard !sensitive else { return }

        // Text takes priority when both are somehow present.
        if let text = pasteboard.string(forType: .string) {
            if let value = guardLogic.outgoingText(me: identity.deviceId, text: text, sensitive: sensitive) {
                transportManager.setState(slot: GossipCoreKit.clipboardTextSlot(), valueJSON: value)
            }
            return
        }

        guard let pngData = Self.imagePNGData(from: pasteboard),
              let outgoing = guardLogic.outgoingImage(me: identity.deviceId, png: pngData, sensitive: sensitive) else { return }
        sendClipboardImage(outgoing: outgoing, data: pngData)
    }

    private func sendClipboardImage(outgoing: GossipCoreKit.Outgoing, data: Data) {
        guard let payload = try? JSONDecoder().decode(JSONValue.self, from: Data(outgoing.payloadJson.utf8)) else { return }
        let envelope = Envelope(
            type: outgoing.kind,
            senderId: identity.deviceId,
            broadcast: true,
            hasRawFollowup: true,
            payload: payload
        )
        try? transportManager.send(envelope, withRawFollowup: data)
    }

    // MARK: - Inbound: wire -> local pasteboard

    /// A peer's `clipboard.text` slot changed (main queue).
    func handleIncomingText(valueJSON: String) {
        guard let text = try? guardLogic.incomingText(payloadJson: valueJSON) else { return }

        ClipboardHistoryStore.shared.record(text, remote: true)
        let pasteboard = NSPasteboard.general
        // Already there (e.g. the same text copied on both devices): leave the pasteboard alone instead of rewriting it.
        if pasteboard.string(forType: .string) == text { lastChangeCount = pasteboard.changeCount; return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Record the resulting changeCount so our own poll doesn't treat this as a new local copy and echo it back.
        lastChangeCount = pasteboard.changeCount
    }

    private func handleIncomingImage(_ envelope: Envelope, _ data: Data) {
        guard envelope.type == "clipboard.update",
              let json = try? JSONEncoder().encode(envelope.payload),
              (try? guardLogic.incomingImage(payloadJson: String(decoding: json, as: UTF8.self), png: data)) == true else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)

        lastChangeCount = pasteboard.changeCount
    }

    // MARK: - Content policy (the core's, shared with every platform)

    static let maxTextBytes = 1 << 20
    static let maxImageBytes = 8 << 20

    static func isSensitive(types: [NSPasteboard.PasteboardType]?) -> Bool {
        GossipCoreKit.clipboardIsSensitive(types: (types ?? []).map(\.rawValue))
    }

    static func textAllowed(_ text: String) -> Bool { GossipCoreKit.clipboardTextAllowed(text: text) }

    static func imageBytesAllowed(_ count: Int) -> Bool { GossipCoreKit.clipboardImageBytesAllowed(len: UInt64(max(0, count))) }

    /// Refuses data that isn't a PNG or whose decoded size is a decompression bomb (images are normalized to PNG).
    static func isReasonableImage(_ data: Data) -> Bool { GossipCoreKit.clipboardIsReasonablePng(data: data) }

    // MARK: - Image handling (pure enough to unit test the byte-level parts; pasteboard read is not)

    /// Reads whatever image is currently on the pasteboard (if any) and normalizes it to PNG — regardless of which
    /// representation the source app actually put there (TIFF is the one AppKit guarantees is always present for image
    /// content) — so the wire format is always a single, universally-decodable content type (`image/png`).
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
