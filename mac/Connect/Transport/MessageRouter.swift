import Foundation

/// Dispatches decoded envelopes to registered handlers by `type` prefix
/// (e.g. `"handshake."`, `"presence."`), so later feature modules (clipboard
/// sync, notification mirroring, file transfer, ...) can register their own
/// handlers without touching `TransportManager` or each other.
final class MessageRouter {
    typealias Handler = (Envelope) -> Void

    private var handlers: [String: [Handler]] = [:]
    private let queue = DispatchQueue(label: "com.connect.app.messagerouter")

    /// Registers a handler for every envelope whose `type` starts with `prefix`
    /// (pass e.g. `"presence."` to catch `presence.online`, `presence.offline`, ...,
    /// or `"presence.heartbeat"` for an exact match only).
    func register(prefix: String, handler: @escaping Handler) {
        queue.sync {
            handlers[prefix, default: []].append(handler)
        }
    }

    /// Routes a single decoded envelope to every handler whose registered
    /// prefix matches `envelope.type`. Called on whatever queue the transport
    /// decodes on; handlers are responsible for hopping to the main thread if needed.
    func route(_ envelope: Envelope) {
        let matches: [Handler] = queue.sync {
            handlers.compactMap { prefix, list in
                envelope.type.hasPrefix(prefix) ? list : nil
            }.flatMap { $0 }
        }
        for handler in matches {
            handler(envelope)
        }
    }
}
