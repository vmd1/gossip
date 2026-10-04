import Foundation
import Network

/// WebSocket client for the Android screen bridge (`ws://<phone>:<port>`, see `schema/message-types.md`'s
/// `screen.ready` row). Uses Network.framework's `NWProtocolWebSocket` rather than
/// `URLSessionWebSocketTask` so there's no App Transport Security cleartext question for a bare LAN IP,
/// and the same framework the mesh transport already uses. Every message is a binary WebSocket message
/// sealed by `ScreenCipher` (key from the per-session secret in the Noise-encrypted `screen.ready`);
/// the first one is a hello carrying the session id, and the plaintext of each starts with a kind byte
/// (`0x00` text, `0x01` binary). Nothing on the wire is readable or forgeable without the secret.
final class ScreenBridgeClient {
    enum Event {
        case header(BridgeStreamHeader)
        case message(BridgeMessage)
        case closed(Error?)
    }

    /// Invoked on the client's private serial queue.
    var onEvent: ((Event) -> Void)?

    private let connection: NWConnection
    private let cipher: ScreenCipher
    private let sessionId: String
    private let queue = DispatchQueue(label: "dev.vmd1.gossip.screenbridge")
    private var finished = false
    private var gotHeader = false

    /// - Parameter host: the phone's address as the mesh transport saw it (IPv6 link-local
    ///   hosts must keep their `%zone`, see `TransportManager.hostWithZone(for:)`).
    init?(host: String, port: UInt16, secret: Data, sessionId: String) {
        guard let url = Self.webSocketURL(host: host, port: port) else { return nil }
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 8 * 1024 * 1024
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true // interactive stream: send touch events immediately
        let params = NWParameters(tls: nil, tcp: tcp)
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        connection = NWConnection(to: .url(url), using: params)
        self.cipher = ScreenCipher(secret: secret, sessionId: sessionId, viewer: true)
        self.sessionId = sessionId
    }

    /// NWProtocolWebSocket must be given a URL endpoint so it can build the HTTP upgrade request;
    /// a bare host/port endpoint makes the connection abort (POSIX 53) before anything is sent.
    /// IPv6 literals need brackets, with the `%zone` percent-encoded. A `%zone`/interface suffix on
    /// anything that isn't an IPv6 literal (a Bonjour hostname such as `tablet.local%en0`, or an IPv4
    /// address) is meaningless there and makes the URL invalid, so it is dropped — the connection to a
    /// tablet resolved through Bonjour reports its host that way.
    static func webSocketURL(host: String, port: UInt16) -> URL? {
        let urlHost: String
        if host.contains(":") {
            urlHost = "[\(host.replacingOccurrences(of: "%", with: "%25"))]"
        } else {
            urlHost = host.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? host
        }
        return URL(string: "ws://\(urlHost):\(port)/screen")
    }

    func connect() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendSealed(kind: 0x01, Data(self.sessionId.utf8))
                self.receiveLoop()
            case .waiting(let error):
                // Can't reach the host right now (no route, local-network permission denied, ...).
                // For a direct LAN address this doesn't resolve itself, so fail fast instead of spinning.
                gossipError("Gossip: screen bridge connection waiting: \(error)")
                self.finish(error)
            case .failed(let error):
                gossipError("Gossip: screen bridge connection failed: \(error)")
                self.finish(error)
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// Sends raw scrcpy control-message bytes (binary WebSocket message). Safe from any thread.
    func sendControl(_ data: Data) {
        sendSealed(kind: 0x01, data)
    }

    private func sendSealed(kind: UInt8, _ body: Data) {
        // Sealing assigns the counter; the lock inside `cipher` plus the connection's in-order send
        // keeps wire order equal to counter order only if both happen together.
        sealLock.lock(); defer { sealLock.unlock() }
        guard let sealed = try? cipher.seal(Data([kind]) + body) else { return }
        sendFrame(sealed, opcode: .binary)
    }
    private let sealLock = NSLock()

    func close() {
        queue.async { [weak self] in
            guard let self, !self.finished else { return }
            self.connection.cancel()
        }
    }

    private func sendFrame(_ data: Data, opcode: NWProtocolWebSocket.Opcode) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(identifier: "ws", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(error) }
        })
    }

    private func receiveLoop() {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let error { return self.finish(error) }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .close { return self.finish(nil) }
            if let data, let metadata, metadata.opcode == .binary {
                guard let plain = try? self.cipher.open(data), let kind = plain.first else {
                    return self.finish(nil) // unauthenticated, replayed or malformed: drop the session
                }
                let body = plain.dropFirst()
                if kind == 0x00 {
                    if !self.gotHeader, let header = BridgeStreamHeader.parse(Data(body)) {
                        self.gotHeader = true
                        self.onEvent?(.header(header))
                    }
                } else if kind == 0x01, let message = BridgeMessage.parse(Data(body)) {
                    self.onEvent?(.message(message))
                }
            }
            if !self.finished { self.receiveLoop() }
        }
    }

    private func finish(_ error: Error?) {
        queue.async { [weak self] in
            guard let self, !self.finished else { return }
            self.finished = true
            self.connection.cancel()
            self.onEvent?(.closed(error))
        }
    }
}
