import Foundation
import Combine

struct MessageThread: Identifiable, Equatable {
    let id: String
    let address: String
    let name: String?
    let snippet: String
    let date: Date
    let outgoing: Bool
    let unread: Int
    var title: String { name ?? address }
}

struct ChatMessage: Identifiable, Equatable {
    let id: String
    let date: Date
    let outgoing: Bool
    let body: String
    var failed = false
    var sending = false
}

/// Pure decoding of the phone's `messages.*` payloads, separate from the manager so it can be tested.
enum MessagesWire {
    static func threads(_ payload: JSONValue) -> [MessageThread] {
        (payload["threads"]?.arrayValue ?? []).compactMap { t in
            guard let id = t["id"]?.stringValue, let date = t["date"]?.numberValue else { return nil }
            return MessageThread(
                id: id, address: t["address"]?.stringValue ?? "", name: t["name"]?.stringValue,
                snippet: t["snippet"]?.stringValue ?? "", date: Date(timeIntervalSince1970: date / 1000),
                outgoing: t["outgoing"]?.boolValue ?? false, unread: Int(t["unread"]?.numberValue ?? 0)
            )
        }
    }

    /// Oldest first, ready to draw top to bottom.
    static func messages(_ payload: JSONValue) -> [ChatMessage] {
        (payload["messages"]?.arrayValue ?? []).compactMap { m in
            guard let id = m["id"]?.stringValue, let date = m["date"]?.numberValue else { return nil }
            return ChatMessage(id: id, date: Date(timeIntervalSince1970: date / 1000),
                               outgoing: m["outgoing"]?.boolValue ?? false, body: m["body"]?.stringValue ?? "")
        }.sorted { $0.date < $1.date }
    }

    static func reasonText(_ reason: String?) -> String? {
        switch reason {
        case "disabled": return "Messages is turned off on the phone (Gossip → Settings → Messages)."
        case "no_permission": return "Gossip on the phone doesn't have permission to read texts yet."
        case "invalid": return "That message couldn't be sent (check the number)."
        case "failed": return "The phone couldn't send that message."
        case nil: return nil
        default: return "The phone reported: \(reason!)."
        }
    }
}

/// The Mac side of the Messages app: asks a paired phone (over the encrypted mesh) for its SMS conversations and sends
/// through it. The phone holds the messages and does all the work (`messages.*`, see `schema/message-types.md`).
///
/// Requests are queries and safe to repeat. A send carries a per-attempt `attemptId` and is re-sent with the **same** id
/// until the phone answers, because the phone texts at most once per id.
final class MessagesManager: ObservableObject {
    @Published private(set) var threads: [MessageThread] = []
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var openThreadId: String?
    @Published private(set) var error: String?
    @Published private(set) var phoneId: String?
    @Published private(set) var loading = false

    private let transport: TransportManager
    private let devices: TrustedDevicesStore
    private var threadsRequest: String?
    private var historyRequest: String?
    private var pending: [String: PendingSend] = [:]
    private var retryTimer: Timer?

    private struct PendingSend { let address: String; let body: String; let to: String; var tries: Int; var lastSent: Date; let messageId: String }

    init(transport: TransportManager, devices: TrustedDevicesStore) {
        self.transport = transport
        self.devices = devices
        transport.router.register(prefix: "messages.") { [weak self] envelope in
            DispatchQueue.main.async { self?.handle(envelope) }
        }
        transport.addOnStateChanged { [weak self] change in
            guard change.slot == "messages.state" else { return }
            DispatchQueue.main.async { self?.stateChanged(from: change.deviceId) }
        }
    }

    /// The phones this Mac could use, connected ones first.
    var phones: [TrustedDevice] {
        devices.devices.filter { $0.deviceType == .androidPhone }
            .sorted { (transport.connectedDeviceIds.contains($0.deviceId) ? 0 : 1) < (transport.connectedDeviceIds.contains($1.deviceId) ? 0 : 1) }
    }

    func selectPhone(_ id: String?) {
        phoneId = id
        threads = []; messages = []; openThreadId = nil; error = nil
        refreshThreads()
    }

    /// Picks a phone if none is chosen yet, then loads the conversation list.
    func open() {
        if phoneId == nil || !phones.contains(where: { $0.deviceId == phoneId }) { phoneId = phones.first?.deviceId }
        refreshThreads()
    }

    func refreshThreads() {
        guard FeatureSettings.shared.isEnabled(.messages) else { error = "Messages is turned off in Gossip's Settings on this Mac."; return }
        guard let phoneId else { error = "No paired phone."; return }
        error = nil; loading = true
        let id = UUID().uuidString
        threadsRequest = id
        send("messages.threads_request", to: phoneId, ["requestId": .string(id), "limit": .number(100)])
        if let open = openThreadId { loadHistory(open) }
    }

    func openThread(_ id: String) {
        openThreadId = id
        messages = []
        if !id.isEmpty { loadHistory(id) } // "" is the new-message composer: nothing to load
    }

    private func loadHistory(_ threadId: String) {
        guard let phoneId else { return }
        let id = UUID().uuidString
        historyRequest = id
        send("messages.history_request", to: phoneId, ["requestId": .string(id), "threadId": .string(threadId), "limit": .number(100)])
    }

    /// Sends `body` to `address`. Shows it in the conversation right away, marked sending until the phone confirms.
    func send(body: String, to address: String) {
        guard let phoneId, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let attempt = UUID().uuidString
        let messageId = "local-\(attempt)"
        messages.append(ChatMessage(id: messageId, date: Date(), outgoing: true, body: body, sending: true))
        pending[attempt] = PendingSend(address: address, body: body, to: phoneId, tries: 1, lastSent: Date(), messageId: messageId)
        transmit(attempt)
        retryTimer = retryTimer ?? Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.retryPending() }
    }

    private func transmit(_ attempt: String) {
        guard let p = pending[attempt] else { return }
        send("messages.send", to: p.to, ["attemptId": .string(attempt), "address": .string(p.address), "body": .string(p.body)])
    }

    private func retryPending() {
        for (attempt, p) in pending where Date().timeIntervalSince(p.lastSent) > 4 {
            if p.tries >= 4 {
                markMessage(p.messageId) { $0.sending = false; $0.failed = true }
                pending[attempt] = nil
            } else {
                pending[attempt]?.tries += 1
                pending[attempt]?.lastSent = Date()
                transmit(attempt) // same attemptId: the phone sends it at most once
            }
        }
        if pending.isEmpty { retryTimer?.invalidate(); retryTimer = nil }
    }

    private func markMessage(_ id: String, _ change: (inout ChatMessage) -> Void) {
        if let i = messages.firstIndex(where: { $0.id == id }) { change(&messages[i]) }
    }

    private func stateChanged(from deviceId: String) {
        guard deviceId == phoneId, openThreadId != nil || !threads.isEmpty else { return }
        refreshThreads()
    }

    private func send(_ type: String, to deviceId: String, _ payload: [String: JSONValue]) {
        let envelope = Envelope(type: type, senderId: IdentityKeyStore.shared.deviceId, recipientId: deviceId, ttl: 4, payload: .object(payload))
        try? transport.send(envelope: envelope)
    }

    func handle(_ envelope: Envelope) {
        guard envelope.senderId == phoneId else { return }
        let reason = MessagesWire.reasonText(envelope.payload["reason"]?.stringValue)
        switch envelope.type {
        case "messages.threads":
            guard envelope.payload["requestId"]?.stringValue == threadsRequest else { return }
            loading = false
            error = reason
            if reason == nil { threads = MessagesWire.threads(envelope.payload) }
        case "messages.history":
            guard envelope.payload["requestId"]?.stringValue == historyRequest,
                  envelope.payload["threadId"]?.stringValue == openThreadId else { return }
            if let reason { error = reason; return }
            // Keep messages still waiting for the phone's confirmation at the end.
            let waiting = messages.filter { $0.sending || $0.failed }
            messages = MessagesWire.messages(envelope.payload) + waiting
        case "messages.send_result":
            guard let attempt = envelope.payload["attemptId"]?.stringValue, let p = pending[attempt] else { return } // duplicate result: nothing to do
            pending[attempt] = nil
            if envelope.payload["ok"]?.boolValue == true {
                markMessage(p.messageId) { $0.sending = false }
                refreshThreads()
            } else {
                markMessage(p.messageId) { $0.sending = false; $0.failed = true }
                error = reason
            }
        default:
            break
        }
    }
}
