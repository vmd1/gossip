import Foundation
import Combine

struct MessageThread: Identifiable, Equatable {
    /// `<phoneId>|<phone's thread id>`: unique across phones.
    let id: String
    let phoneId: String
    let phoneName: String
    let remoteId: String
    let address: String
    let name: String?
    let snippet: String
    let date: Date
    let outgoing: Bool
    let unread: Int
    var title: String { name ?? address }

    static func makeId(phoneId: String, remoteId: String) -> String { "\(phoneId)|\(remoteId)" }
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
    static func threads(_ payload: JSONValue, phoneId: String = "", phoneName: String = "") -> [MessageThread] {
        (payload["threads"]?.arrayValue ?? []).compactMap { t in
            guard let id = t["id"]?.stringValue, let date = t["date"]?.numberValue else { return nil }
            return MessageThread(
                id: MessageThread.makeId(phoneId: phoneId, remoteId: id), phoneId: phoneId, phoneName: phoneName, remoteId: id,
                address: t["address"]?.stringValue ?? "", name: t["name"]?.stringValue,
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
        case "disabled": return "Messages is turned off on the phone (Gossip → Settings → Features)."
        case "no_permission": return "Gossip on the phone doesn't have permission to read texts yet (Gossip → Settings → Features → Messages ⋮)."
        case "invalid": return "That message couldn't be sent (check the number)."
        case "failed": return "The phone couldn't send that message."
        case nil: return nil
        default: return "The phone reported: \(reason!)."
        }
    }
}

/// The Mac side of the Messages app: asks every connected paired phone (over the encrypted mesh) for its SMS conversations,
/// merges them into one list like a single Messages account, and sends through the phone a conversation belongs to. The
/// phones hold the messages and do all the work (`messages.*`, see `schema/message-types.md`).
///
/// Requests are queries and safe to repeat. A send carries a per-attempt `attemptId` and is re-sent with the **same** id
/// until the phone answers, because the phone texts at most once per id.
final class MessagesManager: ObservableObject {
    /// Merged across phones, newest first.
    @Published private(set) var threads: [MessageThread] = []
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var openThreadId: String?
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    /// The phone a new conversation (composer) is sent through.
    @Published var composePhoneId: String?

    private let transport: TransportManager
    private let devices: TrustedDevicesStore
    private var byPhone: [String: [MessageThread]] = [:]
    private var threadsRequests: [String: String] = [:]   // phoneId -> latest requestId
    private var historyRequest: (phoneId: String, requestId: String)?
    private var pending: [String: PendingSend] = [:]
    private var retryTimer: Timer?
    /// Set after sending to a new number from the composer, so the conversation opens once the phone lists it.
    private var openAddressWhenListed: String?
    /// `true` while the Messages window is open: connection changes and a periodic tick then refresh the list.
    private var isOpen = false
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?

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
        // A phone that connects (or reconnects) after the window opened must not leave "isn't connected" on screen.
        Publishers.Merge3(transport.$connectedDeviceIds.map { _ in () }, transport.$meshReachableDeviceIds.map { _ in () },
                          transport.$relayedDeviceIds.map { _ in () })
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] in if self?.isOpen == true { self?.refreshThreads() } }
            .store(in: &cancellables)
    }

    /// Paired phones, connected ones first.
    var phones: [TrustedDevice] {
        devices.devices.filter { $0.deviceType == .androidPhone }
            .sorted { (isReachable($0.deviceId) ? 0 : 1) < (isReachable($1.deviceId) ? 0 : 1) }
    }

    var reachablePhones: [TrustedDevice] { phones.filter { isReachable($0.deviceId) } }

    private func isReachable(_ id: String) -> Bool {
        transport.connectedDeviceIds.contains(id) || transport.meshReachableDeviceIds.contains(id) || transport.relayedDeviceIds.contains(id)
    }

    var openThread: MessageThread? { threads.first { $0.id == openThreadId } }

    /// Loads the conversation list from every connected phone.
    func open() {
        isOpen = true
        // Self-healing: a reply or connection change can be missed, so the list is also re-requested every 15 s while open
        // (a repeat request just gets a fresh answer).
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            if self?.isOpen == true { self?.refreshThreads() }
        }
        if composePhoneId == nil || !phones.contains(where: { $0.deviceId == composePhoneId }) { composePhoneId = reachablePhones.first?.deviceId ?? phones.first?.deviceId }
        refreshThreads()
    }

    /// The Messages window closed: stop refreshing in the background.
    func close() {
        isOpen = false
        refreshTimer?.invalidate(); refreshTimer = nil
    }

    func refreshThreads() {
        guard FeatureSettings.shared.isEnabled(.messages) else { error = "Messages is turned off in Gossip's Settings on this Mac."; return }
        guard !phones.isEmpty else { error = "No paired phone."; return }
        let targets = reachablePhones
        guard !targets.isEmpty else {
            // Not an error yet: Gossip may have just started. The connection observer refreshes as soon as a phone appears.
            error = threads.isEmpty ? "Connecting to your phone…" : "Your phone isn't connected. Showing the last conversations."
            loading = false
            return
        }
        error = nil; loading = true
        for phone in targets {
            let id = UUID().uuidString
            threadsRequests[phone.deviceId] = id
            send("messages.threads_request", to: phone.deviceId, ["requestId": .string(id), "limit": .number(100)])
        }
        if let open = openThread { loadHistory(open) }
    }

    func openThread(_ id: String?) {
        openThreadId = id
        messages = []
        if let t = openThread { loadHistory(t) }
    }

    func startComposing() {
        openThreadId = nil
        messages = []
    }

    private func loadHistory(_ thread: MessageThread) {
        let id = UUID().uuidString
        historyRequest = (thread.phoneId, id)
        send("messages.history_request", to: thread.phoneId, ["requestId": .string(id), "threadId": .string(thread.remoteId), "limit": .number(100)])
    }

    /// Sends `body` to `address` through `phoneId`. Shows it in the conversation right away, marked sending until the phone confirms.
    func send(body: String, to address: String, via phoneId: String) {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let attempt = UUID().uuidString
        let messageId = "local-\(attempt)"
        messages.append(ChatMessage(id: messageId, date: Date(), outgoing: true, body: body, sending: true))
        if openThreadId == nil { openAddressWhenListed = address }
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
        guard byPhone[deviceId] != nil || openThreadId != nil else { return }
        refreshThreads()
    }

    private func send(_ type: String, to deviceId: String, _ payload: [String: JSONValue]) {
        let envelope = Envelope(type: type, senderId: IdentityKeyStore.shared.deviceId, recipientId: deviceId, ttl: 4, payload: .object(payload))
        try? transport.send(envelope: envelope)
    }

    private func rebuild() {
        threads = byPhone.values.flatMap { $0 }.sorted { $0.date > $1.date }
        if openThreadId == nil, let address = openAddressWhenListed {
            let digits = { (s: String) in String(s.filter(\.isNumber).suffix(10)) }
            if let t = threads.first(where: { digits($0.address) == digits(address) && !digits(address).isEmpty }) {
                openAddressWhenListed = nil
                let waiting = messages
                openThread(t.id)
                messages = waiting // keep the just-sent message on screen until the history arrives
            }
        }
    }

    func handle(_ envelope: Envelope) {
        let phoneId = envelope.senderId
        guard let phone = phones.first(where: { $0.deviceId == phoneId }) else { return }
        let reason = MessagesWire.reasonText(envelope.payload["reason"]?.stringValue)
        switch envelope.type {
        case "messages.threads":
            guard envelope.payload["requestId"]?.stringValue == threadsRequests[phoneId] else { return }
            loading = false
            if let reason { error = reason; byPhone[phoneId] = nil } else {
                error = nil
                byPhone[phoneId] = MessagesWire.threads(envelope.payload, phoneId: phoneId, phoneName: phone.deviceName)
            }
            rebuild()
        case "messages.history":
            guard let h = historyRequest, h.phoneId == phoneId, envelope.payload["requestId"]?.stringValue == h.requestId,
                  envelope.payload["threadId"]?.stringValue == openThread?.remoteId else { return }
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
