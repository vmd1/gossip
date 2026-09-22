import Foundation
import UserNotifications

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
    static let replyCategoryIdentifier = "com.connect.app.notification.reply"
    static let replyActionIdentifier = "com.connect.app.notification.replyAction"

    /// Prefix applied to the Android-supplied notification `id` to form the local
    /// `UNNotificationRequest` identifier, so `notification.removed` (and a received
    /// reply) can map back to the originating Android notification without a separate
    /// side table.
    private static let identifierPrefix = "com.connect.app.androidNotification."

    private weak var transportManager: TransportManager?
    private let identity: IdentityKeyStore
    private let notificationCenter = UNUserNotificationCenter.current()

    init(transportManager: TransportManager, identity: IdentityKeyStore = .shared) {
        self.transportManager = transportManager
        self.identity = identity
        super.init()
        registerCategory()
        registerHandlers()
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
    }

    /// Requests local-notification authorization if not already granted/denied.
    /// Safe to call repeatedly (e.g. on every launch); macOS only prompts once.
    func requestAuthorizationIfNeeded() {
        notificationCenter.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            self.notificationCenter.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                if let error {
                    NSLog("Connect: notification authorization request failed: \(error)")
                } else {
                    NSLog("Connect: notification authorization granted=\(granted)")
                }
            }
        }
    }

    // MARK: - Inbound: notification.posted / notification.removed

    private func handlePosted(_ envelope: Envelope) {
        guard let posted = try? decode(NotificationPostedPayload.self, from: envelope.payload) else {
            NSLog("Connect: failed to decode notification.posted payload")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = posted.appName
        content.subtitle = posted.title
        content.body = posted.body
        content.userInfo = ["androidNotificationId": posted.id]
        if posted.hasReplyAction {
            content.categoryIdentifier = Self.replyCategoryIdentifier
        }

        attachIcon(base64: posted.iconBase64, to: content) { [weak self] contentWithIcon in
            guard let self else { return }
            let request = UNNotificationRequest(
                identifier: self.localIdentifier(for: posted.id),
                content: contentWithIcon,
                trigger: nil
            )
            self.notificationCenter.add(request) { error in
                if let error {
                    NSLog("Connect: failed to post mirrored notification: \(error)")
                }
            }
        }
    }

    private func handleRemoved(_ envelope: Envelope) {
        guard let removed = try? decode(NotificationRemovedPayload.self, from: envelope.payload) else {
            NSLog("Connect: failed to decode notification.removed payload")
            return
        }
        notificationCenter.removeDeliveredNotifications(withIdentifiers: [localIdentifier(for: removed.id)])
    }

    private func attachIcon(base64: String?, to content: UNMutableNotificationContent, completion: @escaping (UNMutableNotificationContent) -> Void) {
        guard let base64, let data = Data(base64Encoded: base64) else {
            completion(content)
            return
        }
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        do {
            try data.write(to: tmpURL)
            let attachment = try UNNotificationAttachment(identifier: UUID().uuidString, url: tmpURL, options: nil)
            content.attachments = [attachment]
        } catch {
            NSLog("Connect: failed to attach notification icon: \(error)")
        }
        completion(content)
    }

    // MARK: - Outbound: notification.reply

    private func sendReply(id: String, text: String) {
        guard let transportManager else { return }
        do {
            let payloadData = try JSONEncoder().encode(NotificationReplyPayload(id: id, text: text))
            let payloadJSON = try JSONDecoder().decode(JSONValue.self, from: payloadData)
            let envelope = Envelope(
                type: "notification.reply",
                senderId: identity.deviceId,
                broadcast: true,
                payload: payloadJSON
            )
            try transportManager.send(envelope: envelope)
        } catch {
            NSLog("Connect: failed to send notification.reply: \(error)")
        }
    }

    // MARK: - Helpers

    func localIdentifier(for androidId: String) -> String {
        Self.identifierPrefix + androidId
    }

    func androidId(fromLocalIdentifier identifier: String) -> String? {
        guard identifier.hasPrefix(Self.identifierPrefix) else { return nil }
        return String(identifier.dropFirst(Self.identifierPrefix.count))
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

    /// Catches the user's inline reply (or a plain notification tap) and, for a reply,
    /// forwards the typed text back to Android as `notification.reply`.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        guard response.actionIdentifier == Self.replyActionIdentifier,
              let textResponse = response as? UNTextInputNotificationResponse,
              let androidId = androidId(fromLocalIdentifier: response.notification.request.identifier)
        else { return }

        sendReply(id: androidId, text: textResponse.userText)
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

struct NotificationReplyPayload: Codable {
    let id: String
    let text: String
}
