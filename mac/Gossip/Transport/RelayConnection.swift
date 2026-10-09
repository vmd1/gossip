import Foundation

/// The one WebSocket to the relay, as a thin adapter over `URLSessionWebSocketTask`. It owns no protocol: the Rust
/// engine decides when to connect, what to send and when to give up (`CoreBridge` relay actions); this class opens the
/// socket, delivers what arrives and writes what the engine returns.
///
/// Threading: every callback is delivered on `queue` (the `TransportManager` serial queue), because the session's
/// delegate queue is that queue. Methods must be called on `queue` too. Writes are serialized (one in flight at a
/// time) so the order of the engine's output is the order on the wire, which the Noise nonces depend on.
///
/// Lifetime: one instance per connection attempt. `close()` detaches it, so a late callback from a socket the engine
/// already abandoned can never reach the next connection, and `onClosed` is not called for a close we asked for.
final class RelayConnection: NSObject, URLSessionWebSocketDelegate {
    /// The relay's largest frame is 16 MiB plus a 16 byte header; URLSession's default message limit is 1 MiB.
    static let maximumMessageSize = 20 * 1024 * 1024
    static let pingInterval: TimeInterval = 30
    static let connectTimeout: TimeInterval = 15

    private let queue: DispatchQueue
    private let onOpen: () -> Void
    private let onText: (String) -> Void
    private let onBinary: (Data) -> Void
    private let onClosed: () -> Void

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var detached = false
    private var opened = false
    private var pingTimer: DispatchSourceTimer?
    private var pingOutstanding = false

    private enum Outgoing { case text(String), binary(Data) }
    private var pending: [Outgoing] = []
    private var writing = false

    /// `url` must already have passed `RelayEndpointPolicy.validateConnectURL`.
    init(url: URL, queue: DispatchQueue, onOpen: @escaping () -> Void, onText: @escaping (String) -> Void,
         onBinary: @escaping (Data) -> Void, onClosed: @escaping () -> Void) {
        self.queue = queue
        self.onOpen = onOpen
        self.onText = onText
        self.onBinary = onBinary
        self.onClosed = onClosed
        super.init()

        let operations = OperationQueue()
        operations.underlyingQueue = queue
        operations.maxConcurrentOperationCount = 1
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.connectTimeout
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: operations)
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.connectTimeout
        let task = session!.webSocketTask(with: request)
        task.maximumMessageSize = Self.maximumMessageSize
        self.task = task
        task.resume()
        receiveNext(task)
    }

    // MARK: - Sending

    func sendText(_ text: String) { enqueue(.text(text)) }
    func sendBinary(_ data: Data) { enqueue(.binary(data)) }

    private func enqueue(_ message: Outgoing) {
        guard !detached else { return }
        pending.append(message)
        writeNext()
    }

    private func writeNext() {
        guard !writing, !detached, let task, !pending.isEmpty else { return }
        writing = true
        let message = pending.removeFirst()
        let completion: (Error?) -> Void = { [weak self] error in
            // `URLSessionWebSocketTask` completes on the session's delegate queue, which is `queue`.
            guard let self, !self.detached else { return }
            self.writing = false
            if let error {
                gossipError("Gossip: relay send failed: \(error.localizedDescription)")
                self.failed()
            } else {
                self.writeNext()
            }
        }
        switch message {
        case .text(let text): task.send(.string(text), completionHandler: completion)
        case .binary(let data): task.send(.data(data), completionHandler: completion)
        }
    }

    // MARK: - Receiving

    private func receiveNext(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self, !self.detached, self.task === task else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text): self.onText(text)
                case .data(let data): self.onBinary(data)
                @unknown default: break
                }
                if !self.detached { self.receiveNext(task) }
            case .failure:
                self.failed()
            }
        }
    }

    // MARK: - Liveness

    private func startPinging() {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval)
        timer.setEventHandler { [weak self] in
            guard let self, !self.detached, let task = self.task else { return }
            // The previous ping never got its pong in a whole interval: the path is dead even if TCP has not noticed.
            if self.pingOutstanding {
                gossipError("Gossip: relay ping timed out")
                self.failed()
                return
            }
            self.pingOutstanding = true
            task.sendPing { [weak self] error in
                guard let self, !self.detached else { return }
                self.pingOutstanding = false
                if error != nil { self.failed() }
            }
        }
        timer.resume()
        pingTimer = timer
    }

    // MARK: - Closing

    /// Detaches and closes the socket without reporting back (the engine asked for it, or this is teardown).
    func close() {
        guard !detached else { return }
        detached = true
        pingTimer?.cancel()
        pingTimer = nil
        pending.removeAll()
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }

    /// The socket died by itself: tell the engine once, then release everything.
    private func failed() {
        guard !detached else { return }
        close()
        onClosed()
    }

    // MARK: - URLSessionWebSocketDelegate (called on `queue`)

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard !detached, webSocketTask === task, !opened else { return }
        opened = true
        startPinging()
        onOpen()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard webSocketTask === task else { return }
        failed()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task else { return }
        if let error { gossipError("Gossip: relay socket ended: \((error as NSError).domain) \((error as NSError).code)") }
        failed()
    }

    /// A relay never redirects; following one would send the join to a host that was not validated.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
