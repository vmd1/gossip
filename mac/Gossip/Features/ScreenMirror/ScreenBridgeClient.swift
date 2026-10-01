import Foundation
import Network

/// WebSocket client for the Android screen bridge (`ws://<phone>:<port>`, token as the first
/// message — see `schema/message-types.md`'s `screen.ready` row). Uses Network.framework's
/// `NWProtocolWebSocket` rather than `URLSessionWebSocketTask` so there's no App Transport
/// Security cleartext question for a bare LAN IP, and the same framework the mesh transport
/// already uses. **Not encrypted**: the token authenticates the viewer, but the stream itself is
/// plaintext on the LAN (documented limitation, `android/screen-server/README.md`).
final class ScreenBridgeClient {
    enum Event {
        case header(BridgeStreamHeader)
        case message(BridgeMessage)
        case closed(Error?)
    }

    /// Invoked on the client's private serial queue.
    var onEvent: ((Event) -> Void)?

    private let connection: NWConnection
    private let token: String
    private let queue = DispatchQueue(label: "dev.vmd1.gossip.screenbridge")
    private var finished = false
    private var gotHeader = false

    /// - Parameter host: the phone's address as the mesh transport saw it (IPv6 link-local
    ///   hosts must keep their `%zone`, see `TransportManager.hostWithZone(for:)`).
    init?(host: String, port: UInt16, token: String) {
        guard let url = Self.webSocketURL(host: host, port: port) else { return nil }
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 8 * 1024 * 1024
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        connection = NWConnection(to: .url(url), using: params)
        self.token = token
    }

    /// NWProtocolWebSocket must be given a URL endpoint so it can build the HTTP upgrade request;
    /// a bare host/port endpoint makes the connection abort (POSIX 53) before anything is sent.
    /// IPv6 literals need brackets, with the `%zone` percent-encoded.
    static func webSocketURL(host: String, port: UInt16) -> URL? {
        let urlHost = host.contains(":") ? "[\(host.replacingOccurrences(of: "%", with: "%25"))]" : host
        return URL(string: "ws://\(urlHost):\(port)/screen")
    }

    func connect() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendFrame(Data(self.token.utf8), opcode: .text)
                self.receiveLoop()
            case .waiting(let error):
                // Can't reach the host right now (no route, local-network permission denied, ...).
                // For a direct LAN address this doesn't resolve itself, so fail fast instead of spinning.
                NSLog("Gossip: screen bridge connection waiting: \(error)")
                self.finish(error)
            case .failed(let error):
                NSLog("Gossip: screen bridge connection failed: \(error)")
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
        sendFrame(data, opcode: .binary)
    }

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
            if let data, let metadata {
                switch metadata.opcode {
                case .text:
                    if !self.gotHeader, let header = BridgeStreamHeader.parse(data) {
                        self.gotHeader = true
                        self.onEvent?(.header(header))
                    }
                case .binary:
                    if let message = BridgeMessage.parse(data) { self.onEvent?(.message(message)) }
                default:
                    break
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
