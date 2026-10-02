import Foundation
import Network

/// The encrypted data channel to one device: a WebSocket (`ws://<device>:<port>/control`) whose messages are
/// `ControlCipher` frames (see `ControlProtocol.swift`). The first frame is an encrypted `hello` carrying the
/// session id — proof of key possession, replacing the plaintext token the screen bridge uses. Input rides
/// this channel and never the mesh.
final class ControlWebSocketClient {
    enum Event {
        /// Connected and the device answered the hello.
        case ready(ControlDisplayInfo)
        case frame(ControlFrame)
        case closed(Error?)
    }

    /// Invoked on the client's private serial queue.
    var onEvent: ((Event) -> Void)?

    private let connection: NWConnection
    private let sessionId: String
    private var cipher: ControlCipher
    private let queue: DispatchQueue
    private var finished = false
    private var gotHelloAck = false

    init?(host: String, port: UInt16, sessionId: String, secret: Data, label: String = "control") {
        guard let url = Self.webSocketURL(host: host, port: port) else { return nil }
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 1 << 20
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true // pointer motion: never let Nagle hold a small frame back
        let params = NWParameters(tls: nil, tcp: tcp)
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        connection = NWConnection(to: .url(url), using: params)
        self.sessionId = sessionId
        cipher = ControlCipher(secret: secret, sessionId: sessionId, role: .macToDevice)
        queue = DispatchQueue(label: "dev.vmd1.gossip.control.\(label)", qos: .userInteractive)
    }

    /// Same URL rules as `ScreenBridgeClient.webSocketURL`.
    static func webSocketURL(host: String, port: UInt16) -> URL? {
        let urlHost: String
        if host.contains(":") {
            urlHost = "[\(host.replacingOccurrences(of: "%", with: "%25"))]"
        } else {
            urlHost = host.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? host
        }
        return URL(string: "ws://\(urlHost):\(port)/control")
    }

    func connect() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendNow(.hello(sessionId: self.sessionId))
                self.receiveLoop()
            case .waiting(let error), .failed(let error):
                self.finish(error)
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// Safe from any thread. Frames sent before the hello is acknowledged are queued behind it by order.
    func send(_ frame: ControlFrame) {
        queue.async { [weak self] in self?.sendNow(frame) }
    }

    func close() {
        queue.async { [weak self] in
            guard let self, !self.finished else { return }
            self.connection.cancel()
        }
    }

    private func sendNow(_ frame: ControlFrame) {
        guard !finished, let data = try? cipher.seal(frame) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
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
            if let data, metadata?.opcode == .binary {
                do {
                    if let frame = try self.cipher.open(data) {
                        if !self.gotHelloAck {
                            if case .helloAck(let info) = frame {
                                self.gotHelloAck = true
                                self.onEvent?(.ready(info))
                            } else {
                                return self.finish(ControlCipher.Failure.authentication)
                            }
                        } else {
                            self.onEvent?(.frame(frame))
                        }
                    }
                } catch ControlCipher.Failure.replayed {
                    // A duplicated/replayed frame is simply dropped.
                } catch {
                    return self.finish(error) // forged or corrupt: the channel is not trustworthy
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
