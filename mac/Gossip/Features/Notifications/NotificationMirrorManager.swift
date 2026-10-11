import Foundation
import UserNotifications
import ImageIO

/// Mirrors Android notifications (`notification.posted` / `notification.removed`) onto
/// this Mac as local `UserNotifications`, and — for notifications whose source supports
/// a chat-style text reply (`hasReplyAction`) — lets the user reply inline from the Mac
/// notification banner, sending the typed text back to Android as `notification.reply`
/// so it round-trips into the real Android conversation.
///
/// Registers its two inbound handlers with `TransportManager.router` and installs itself
/// as the `UNUserNotificationCenterDelegate` (wired up from `ConnectApp`/`AppDelegate`,
/// following the same "feature owns its own wiring" pattern as `PairingViewModel`).
final class NotificationMirrorManager: NSObject, ObservableObject {
    static let replyCategoryIdentifier = "dev.vmd1.gossip.notification.reply"
    static let replyActionIdentifier = "dev.vmd1.gossip.notification.replyAction"

    /// Prefix applied to the source device ID + Android-supplied notification `id` to
    /// form the local `UNNotificationRequest` identifier, so `notification.removed` (and
    /// a received reply/dismiss) can map back to both the originating *device* and its
    /// notification without a separate side table. Encoding the source device matters
    /// once more than one Android device can post notifications into the mesh — a bare
    /// `id` could otherwise collide between two different phones/tablets, and a reply or
    /// dismiss must be routed back to the specific device that posted the original
    /// notification, not broadcast to all of them.
    private static let identifierPrefix = "dev.vmd1.gossip.androidNotification."
    private static let identifierSeparator = "|"

    private weak var transportManager: TransportManager?
    private let identity: IdentityKeyStore
    private let notificationCenter = UNUserNotificationCenter.current()

    /// What we believe is showing, what was removed, and what the user dismissed here; see `NotificationMirrorBook`
    /// and `pollForDismissedNotifications`'s doc for why it exists.
    private let book = NotificationMirrorBook()
    private var dismissPollTimer: Timer?

    /// Drives the "notifications disabled" warning in `MenuBarView`. Mirroring degrades
    /// silently otherwise: `UNUserNotificationCenter.add(_:)` (in `handlePosted`) succeeds
    /// and calls back with no error even when the user has denied/turned off notification
    /// permission for this app in System Settings — it just never shows anything. This
    /// was the actual cause of a "notification mirroring doesn't work" report that had
    /// nothing wrong with the transport or listener code on either platform.
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    init(transportManager: TransportManager, identity: IdentityKeyStore = .shared) {
        self.transportManager = transportManager
        self.identity = identity
        super.init()
        registerCategory()
        registerHandlers()
        refreshAuthorizationStatus()
        startDismissPolling()
    }

    /// Re-queries the current authorization status. The user can flip this in System
    /// Settings at any time outside the app, so callers should refresh at moments that
    /// are actually informative — e.g. `ConnectApp` does this on every transport
    /// reconnect, since that's when a real mirrored notification is about to matter.
    func refreshAuthorizationStatus() {
        notificationCenter.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.authorizationStatus = settings.authorizationStatus
            }
        }
    }

    // MARK: - Setup

    /// Registers the `UNNotificationCategory` carrying the inline-reply action, so any
    /// notification posted with this category shows a reply field. Must happen before a
    /// notification using it is delivered (safe to call multiple times).
    private func registerCategory() {
        let replyAction = UNTextInputNotificationAction(
            identifier: Self.replyActionIdentifier,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Message"
        )
        let category = UNNotificationCategory(
            identifier: Self.replyCategoryIdentifier,
            actions: [replyAction],
            intentIdentifiers: [],
            options: []
        )
        notificationCenter.getNotificationCategories { existing in
            self.notificationCenter.setNotificationCategories(existing.union([category]))
        }
    }

    private func registerHandlers() {
        transportManager?.router.register(prefix: "notification.posted") { [weak self] envelope in
            self?.handlePosted(envelope)
        }
        transportManager?.router.register(prefix: "notification.removed") { [weak self] envelope in
            self?.handleRemoved(envelope)
        }
        transportManager?.router.register(prefix: "notification.sync") { [weak self] envelope in
            self?.handleSync(envelope)
        }
    }

    /// Requests local-notification authorization if not already granted/denied.
    /// Safe to call repeatedly (e.g. on every launch); macOS only prompts once.
    func requestAuthorizationIfNeeded() {
        notificationCenter.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            self.notificationCenter.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                if let error {
                    gossipError("Gossip: notification authorization request failed: \(error)")
                } else {
                    NSLog("Gossip: notification authorization granted=\(granted)")
                }
                self.refreshAuthorizationStatus()
            }
        }
    }

    // MARK: - Inbound: notification.posted / notification.removed

    private func handlePosted(_ envelope: Envelope) {
        guard let posted = try? decode(NotificationPostedPayload.self, from: envelope.payload) else {
            gossipError("Gossip: failed to decode notification.posted payload")
            return
        }

        let postedIdentifier = localIdentifier(for: posted.id, sourceDeviceId: envelope.senderId)
        if book.isStale(postedIdentifier, postedAt: posted.timestamp) { return }

        let content = UNMutableNotificationContent()
        content.title = String(posted.appName.prefix(80))
        content.subtitle = String(posted.title.prefix(200))
        content.body = String(posted.body.prefix(2000))
        content.userInfo = ["androidNotificationId": posted.id, "sourceDeviceId": envelope.senderId]
        if posted.hasReplyAction {
            content.categoryIdentifier = Self.replyCategoryIdentifier
        }

        attachIcon(base64: posted.iconBase64, to: content) { [weak self] contentWithIcon in
            guard let self else { return }
            // The removal may have arrived while the icon was being decoded.
            if self.book.isStale(postedIdentifier, postedAt: posted.timestamp) { return }
            let request = UNNotificationRequest(
                identifier: postedIdentifier,
                content: contentWithIcon,
                trigger: nil
            )
            self.notificationCenter.add(request) { [weak self] error in
                if let error {
                    gossipError("Gossip: failed to post mirrored notification: \(error)")
                } else {
                    self?.book.recordShown(request.identifier)
                }
            }
        }
    }

    private func handleRemoved(_ envelope: Envelope) {
        guard let removed = try? decode(NotificationRemovedPayload.self, from: envelope.payload) else {
            gossipError("Gossip: failed to decode notification.removed payload")
            return
        }
        let identifier = localIdentifier(for: removed.id, sourceDeviceId: envelope.senderId)
        book.recordRemoval(identifier, at: envelope.ts)
        notificationCenter.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    /// `notification.sync`: the phone's list of notifications it is still mirroring. Anything from that phone shown here
    /// that is not on the list (and has been here for more than `syncGrace`) was a lost `notification.removed`, so it is
    /// removed. Anything the user dismissed here that the phone still lists was a lost `notification.dismiss`, so it is
    /// sent again. Applying the same list twice changes nothing.
    private func handleSync(_ envelope: Envelope) {
        guard let sync = try? decode(NotificationSyncPayload.self, from: envelope.payload) else {
            gossipError("Gossip: failed to decode notification.sync payload")
            return
        }
        let sender = envelope.senderId
        let live = Set(sync.ids.map { localIdentifier(for: $0, sourceDeviceId: sender) })
        let outcome = book.applySync(liveIdentifiers: live, owns: { [weak self] in self?.decodeLocalIdentifier($0)?.sourceDeviceId == sender })
        if !outcome.remove.isEmpty { notificationCenter.removeDeliveredNotifications(withIdentifiers: outcome.remove) }
        for identifier in outcome.redismiss {
            if let (source, androidId) = decodeLocalIdentifier(identifier) { sendDismiss(id: androidId, to: source) }
        }
    }

    /// Self-healing substitute for a dismiss callback macOS won't reliably give us: unlike
    /// iOS, `userNotificationCenter(_:didReceive:)` is *not* consistently invoked with
    /// `UNNotificationDismissActionIdentifier` for a plain banner swipe/close on macOS
    /// (confirmed directly — zero deliveries for a swipe-dismissed banner in testing, even
    /// with unconditional logging at the very top of that delegate method, so this isn't a
    /// bug in how we handle the callback, the callback itself just doesn't come). Instead,
    /// periodically diff the real delivered-notifications list against the book of shown notifications
    /// (everything we posted and haven't already resolved): anything that dropped out
    /// without us removing it ourselves was dismissed by the user, so tell Android.
    private func startDismissPolling() {
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.pollForDismissedNotifications()
        }
        RunLoop.main.add(timer, forMode: .common)
        dismissPollTimer = timer
    }

    private func pollForDismissedNotifications() {
        guard !book.isEmpty else { return }
        notificationCenter.getDeliveredNotifications { [weak self] delivered in
            guard let self else { return }
            let stillShowing = Set(delivered.map { $0.request.identifier })
            let dismissedIdentifiers = self.book.shownIdentifiers.subtracting(stillShowing)
            guard !dismissedIdentifiers.isEmpty else { return }
            DispatchQueue.main.async {
                for identifier in dismissedIdentifiers {
                    self.book.recordDismissedHere(identifier)
                    if let (sourceDeviceId, androidId) = self.decodeLocalIdentifier(identifier) {
                        self.sendDismiss(id: androidId, to: sourceDeviceId)
                    }
                }
            }
        }
    }

    private func attachIcon(base64: String?, to content: UNMutableNotificationContent, completion: @escaping (UNMutableNotificationContent) -> Void) {
        guard let base64, base64.utf8.count <= Self.maxIconBase64Chars, let data = Data(base64Encoded: base64),
              Self.isReasonableIcon(data) else {
            completion(content)
            return
        }
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        do {
            try data.write(to: tmpURL)
            let attachment = try UNNotificationAttachment(identifier: UUID().uuidString, url: tmpURL, options: nil)
            content.attachments = [attachment]
        } catch {
            gossipError("Gossip: failed to attach notification icon: \(error)")
            try? FileManager.default.removeItem(at: tmpURL) // a rejected attachment isn't moved, so don't leave it behind
        }
        completion(content)
    }

    static let maxIconBase64Chars = 400_000
    static let maxIconBytes = 256 * 1024
    static let maxIconPixels = 4_000_000

    /// A real, modestly sized image: refuses non-images and decompression bombs before anything touches disk.
    static func isReasonableIcon(_ data: Data) -> Bool {
        guard data.count <= maxIconBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return false }
        return w * h <= maxIconPixels
    }

    // MARK: - Outbound: notification.reply

    /// Targeted at the specific device that posted the original notification — not
    /// broadcast — since with more than one Android device in the mesh, a reply must
    /// only be delivered to whichever one actually owns that notification/conversation.
    private func sendReply(id: String, text: String, to sourceDeviceId: String) {
        guard let transportManager else { return }
        do {
            let payloadData = try JSONEncoder().encode(NotificationReplyPayload(id: id, text: text, attemptId: UUID().uuidString))
            let payloadJSON = try JSONDecoder().decode(JSONValue.self, from: payloadData)
            let envelope = Envelope(
                type: "notification.reply",
                senderId: identity.deviceId,
                recipientId: sourceDeviceId,
                payload: payloadJSON
            )
            try transportManager.send(envelope: envelope)
        } catch {
            gossipError("Gossip: failed to send notification.reply: \(error)")
        }
    }

    // MARK: - Outbound: notification.dismiss

    /// Targeted at the specific device that posted the original notification — see
    /// `sendReply`'s doc for why this can't be a broadcast once there's more than one
    /// Android device in the mesh.
    private func sendDismiss(id: String, to sourceDeviceId: String) {
        guard let transportManager else { return }
        do {
            let payloadData = try JSONEncoder().encode(NotificationDismissPayload(id: id))
            let payloadJSON = try JSONDecoder().decode(JSONValue.self, from: payloadData)
            let envelope = Envelope(
                type: "notification.dismiss",
                senderId: identity.deviceId,
                recipientId: sourceDeviceId,
                payload: payloadJSON
            )
            try transportManager.send(envelope: envelope)
        } catch {
            gossipError("Gossip: failed to send notification.dismiss: \(error)")
        }
    }

    // MARK: - Helpers

    func localIdentifier(for androidId: String, sourceDeviceId: String) -> String {
        Self.identifierPrefix + sourceDeviceId + Self.identifierSeparator + androidId
    }

    /// Splits a local identifier back into `(sourceDeviceId, androidId)`. Returns `nil`
    /// for anything not produced by `localIdentifier(for:sourceDeviceId:)` — including,
    /// notably, identifiers from a pre-mesh build that only encoded a bare `androidId`
    /// with no separator; there's no way to recover a source device for those, so they're
    /// just treated as unrecognized rather than guessed at.
    func decodeLocalIdentifier(_ identifier: String) -> (sourceDeviceId: String, androidId: String)? {
        guard identifier.hasPrefix(Self.identifierPrefix) else { return nil }
        let remainder = identifier.dropFirst(Self.identifierPrefix.count)
        guard let separatorIndex = remainder.range(of: Self.identifierSeparator) else { return nil }
        let sourceDeviceId = String(remainder[remainder.startIndex..<separatorIndex.lowerBound])
        let androidId = String(remainder[separatorIndex.upperBound...])
        return (sourceDeviceId, androidId)
    }

    func decode<T: Decodable>(_ type: T.Type, from payload: JSONValue) throws -> T {
        let data = try JSONEncoder().encode(payload)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationMirrorManager: UNUserNotificationCenterDelegate {
    /// Shows mirrored notifications even while Connect is the frontmost app.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    /// Catches the user's inline reply, a plain notification tap, or an explicit dismiss
    /// (swipe away / click the close button — macOS reports this as
    /// `UNNotificationDismissActionIdentifier`, same as iOS) and forwards the
    /// corresponding action back to Android as `notification.reply` / `notification.dismiss`.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        guard let (sourceDeviceId, androidId) = decodeLocalIdentifier(response.notification.request.identifier) else { return }

        switch response.actionIdentifier {
        case Self.replyActionIdentifier:
            guard let textResponse = response as? UNTextInputNotificationResponse else { return }
            sendReply(id: androidId, text: textResponse.userText, to: sourceDeviceId)
        case UNNotificationDismissActionIdentifier:
            // In practice macOS rarely if ever delivers this (see `pollForDismissedNotifications`,
            // the actual mechanism this relies on) — kept as a fast path in case some
            // interaction or future macOS version does provide it.
            book.forget(response.notification.request.identifier)
            sendDismiss(id: androidId, to: sourceDeviceId)
        default:
            break
        }
    }
}

// MARK: - Payload shapes (schema/message-types.md: notification.posted / notification.removed / notification.reply)

struct NotificationPostedPayload: Codable {
    let id: String
    let appPackage: String
    let appName: String
    let title: String
    let body: String
    let iconBase64: String?
    let hasReplyAction: Bool
    let timestamp: Int64
}

struct NotificationRemovedPayload: Codable {
    let id: String
}

/// `notification.sync`: ids of every notification the phone is still mirroring. See `handleSync`.
struct NotificationSyncPayload: Codable {
    let ids: [String]
}

/// `attemptId` identifies this reply *attempt*, not the notification (`id` is reused
/// across distinct replies to the same notification) — the Android receiver keys its
/// recently-handled dedupe cache off it so a duplicate delivery can't fire the same
/// real-world reply twice. See `NotificationListenerImpl.handleReply` (Android).
struct NotificationReplyPayload: Codable {
    let id: String
    let text: String
    let attemptId: String
}

struct NotificationDismissPayload: Codable {
    let id: String
}
