import Foundation
import Combine
import GossipCoreKit

/// The HTTP layer of the relay directory, behind a protocol so tests can fake it. `fetch` calls `completion` exactly
/// once, on any queue, with the raw response body or `nil` for any failure (network, non-200, redirect, oversize).
protocol RelayDirectoryHTTP {
    func fetch(_ url: URL, completion: @escaping (Data?) -> Void)
}

/// The real thing, `URLSession` with the constraints the directory design requires: HTTPS only (plain `http://` to
/// loopback in Debug builds for the local e2e test), a redirect is followed only within the same host and scheme, a 10 s
/// timeout, a 64 KiB body cap, no cookies or credentials, and nothing identifying in the request (no device ids, no
/// headers beyond a generic User-Agent).
final class URLSessionRelayDirectoryHTTP: NSObject, RelayDirectoryHTTP, URLSessionDataDelegate {
    static let timeout: TimeInterval = 10
    static let maximumBodyBytes = 64 * 1024

    private let allowInsecureLoopback: Bool
    private var session: URLSession!
    private let lock = NSLock()
    private var buffers: [Int: Data] = [:]
    private var completions: [Int: (Data?) -> Void] = [:]

    init(allowInsecureLoopback: Bool = RelayEndpointPolicy.allowsInsecureLoopback) {
        self.allowInsecureLoopback = allowInsecureLoopback
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = Self.timeout
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": "Gossip"]
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    static func isAcceptable(_ url: URL, allowInsecureLoopback: Bool) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), url.user == nil, url.password == nil else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && allowInsecureLoopback && RelayEndpointPolicy.isLoopback(host)
    }

    func fetch(_ url: URL, completion: @escaping (Data?) -> Void) {
        guard Self.isAcceptable(url, allowInsecureLoopback: allowInsecureLoopback) else { completion(nil); return }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.timeout
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let task = session.dataTask(with: request)
        lock.lock(); buffers[task.taskIdentifier] = Data(); completions[task.taskIdentifier] = completion; lock.unlock()
        task.resume()
    }

    private func finish(_ task: URLSessionTask, body: Data?) {
        lock.lock()
        let completion = completions.removeValue(forKey: task.taskIdentifier)
        buffers.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        completion?(body)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.expectedContentLength <= Int64(Self.maximumBodyBytes) else {
            completionHandler(.cancel)
            finish(dataTask, body: nil)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        var buffer = buffers[dataTask.taskIdentifier]
        buffer?.append(data)
        let tooBig = (buffer?.count ?? 0) > Self.maximumBodyBytes
        if !tooBig, let buffer { buffers[dataTask.taskIdentifier] = buffer }
        lock.unlock()
        if tooBig {
            dataTask.cancel()
            finish(dataTask, body: nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let body = buffers[task.taskIdentifier]
        lock.unlock()
        finish(task, body: error == nil ? body : nil)
    }

    /// A redirect is followed only to the same host over the same scheme; anything else is refused.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let from = task.originalRequest?.url, let to = request.url,
              from.host?.lowercased() == to.host?.lowercased(), from.scheme?.lowercased() == to.scheme?.lowercased(),
              from.port == to.port, Self.isAcceptable(to, allowInsecureLoopback: allowInsecureLoopback) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

/// Polls the relay directory, keeps the last good answer on disk and tells the transport which relay it names.
///
/// The core (`relay_directory.rs`, through `relayDirectoryDecide`) validates every blob and applies the rule that a
/// failed or invalid fetch never replaces or clears a valid cached copy; this class does the HTTP, the file, the
/// timer and the bookkeeping. It polls only while `setActive(true)` (the relay is switched on), on launch, then on the
/// core's schedule, and once more (rate limited) when the relay socket fails to connect.
final class RelayDirectoryService: ObservableObject {
    static let shared = RelayDirectoryService()

    /// The raw directory blob exactly as received, plus when it was fetched. Written atomically, only after the core
    /// validated it.
    private struct CacheFile: Codable {
        var fetchedAt: Int64   // ms since the Unix epoch
        var raw: String
    }

    /// The relay named by the cached/polled directory, if any (already validated by the core).
    @Published private(set) var cachedOrigin: String?
    /// Whether the last poll succeeded (so the cached answer is current, not just remembered).
    @Published private(set) var isFresh = false
    /// True until the first poll has finished, when polling is on and there is nothing cached: the transport holds the
    /// relay back so it does not connect to the default just before the directory names another relay.
    @Published private(set) var awaitingFirstAnswer = false
    /// When the directory was last fetched successfully (survives restarts).
    @Published private(set) var lastSuccess: Date?

    private let endpoint: String
    private let http: RelayDirectoryHTTP
    private let cacheURL: URL
    private let allowInsecureLocal: Bool
    private let now: () -> Date
    private let scheduler: RelayDirectoryScheduler
    private let queue = DispatchQueue(label: "dev.vmd1.gossip.relaydirectory")

    // State below is only touched on `queue`.
    private var cachedRaw: String?
    private var lastSuccessMs: Int64?
    private var lastAttemptMs: Int64?
    private var failures: UInt32 = 0
    private var inFlight = false
    private var active = false
    private var timer: DispatchSourceTimer?

    static let tickInterval: TimeInterval = 30

    init(endpoint: String = RelayEndpointPolicy.directoryEndpoint,
         http: RelayDirectoryHTTP? = nil,
         cacheURL: URL = RelayDirectoryService.defaultCacheURL(),
         allowInsecureLocal: Bool = RelayEndpointPolicy.allowsInsecureLoopback,
         scheduler: RelayDirectoryScheduler = RelayDirectoryScheduler(),
         now: @escaping () -> Date = Date.init) {
        self.endpoint = endpoint
        self.http = http ?? URLSessionRelayDirectoryHTTP(allowInsecureLoopback: allowInsecureLocal)
        self.cacheURL = cacheURL
        self.allowInsecureLocal = allowInsecureLocal
        self.scheduler = scheduler
        self.now = now
        loadCache()
        awaitingFirstAnswer = pollingEnabled && cachedOrigin == nil
    }

    static func defaultCacheURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Connect", isDirectory: true).appendingPathComponent("relay-directory.json")
    }

    /// Polling is switched off entirely while the endpoint is still the placeholder (the built-in default is used).
    var pollingEnabled: Bool { !endpoint.hasSuffix("/TODO-directory") && URL(string: endpoint) != nil }

    // MARK: - Cache

    /// A missing, unreadable or invalid cache file is ignored (never fatal); the next good fetch overwrites it.
    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL), let file = try? JSONDecoder().decode(CacheFile.self, from: data),
              let origin = relayDirectoryParse(json: file.raw) else { return }
        cachedRaw = file.raw
        lastSuccessMs = file.fetchedAt
        cachedOrigin = origin
        lastSuccess = Date(timeIntervalSince1970: TimeInterval(file.fetchedAt) / 1000)
    }

    private func writeCache(raw: String, fetchedAt: Int64) {
        guard let data = try? JSONEncoder().encode(CacheFile(fetchedAt: fetchedAt, raw: raw)) else { return }
        let directory = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".relay-directory-\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary)
            // `replaceItemAt` swaps atomically when the destination exists; otherwise a plain rename.
            if FileManager.default.fileExists(atPath: cacheURL.path) {
                _ = try FileManager.default.replaceItemAt(cacheURL, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: cacheURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            gossipError("Gossip: could not save the relay directory cache")
        }
    }

    // MARK: - Polling

    /// Starts or stops polling. Call with the relay's enabled state; it does nothing while the endpoint is a placeholder.
    func setActive(_ value: Bool) {
        queue.async { [weak self] in
            guard let self, self.active != value else { return }
            self.active = value
            self.timer?.cancel()
            self.timer = nil
            guard value, self.pollingEnabled else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: Self.tickInterval)
            timer.setEventHandler { [weak self] in self?.tickOnQueue() }
            timer.resume()
            self.timer = timer
        }
    }

    /// Polls if the schedule says it is due. Called by the timer; tests call it directly.
    func tick() { queue.async { [weak self] in self?.tickOnQueue() } }

    /// The relay socket failed to connect: the relay may have moved, so look at the directory (at most every 10 minutes).
    func noteRelayConnectFailure() {
        queue.async { [weak self] in
            guard let self, self.active, self.pollingEnabled, !self.inFlight else { return }
            let nowMs = self.nowMs()
            if self.scheduler.shouldPollAfterConnectFailure(nowMs: nowMs, lastAttemptMs: self.lastAttemptMs) { self.pollOnQueue() }
        }
    }

    /// Blocks until work queued so far has run (tests).
    func flush() { queue.sync {} }

    private func nowMs() -> Int64 { Int64(now().timeIntervalSince1970 * 1000) }

    private func tickOnQueue() {
        guard active, pollingEnabled, !inFlight else { return }
        if scheduler.shouldPoll(nowMs: nowMs(), lastSuccessMs: lastSuccessMs, lastAttemptMs: lastAttemptMs, failures: failures) {
            pollOnQueue()
        }
    }

    private func pollOnQueue() {
        guard let url = URL(string: endpoint), URLSessionRelayDirectoryHTTP.isAcceptable(url, allowInsecureLoopback: allowInsecureLocal) else { return }
        inFlight = true
        lastAttemptMs = nowMs()
        scheduler.reroll()
        http.fetch(url) { [weak self] body in
            self?.queue.async { self?.finishPoll(body: body) }
        }
    }

    private func finishPoll(body: Data?) {
        inFlight = false
        let raw = body.flatMap { String(data: $0, encoding: .utf8) }
        let decision = relayDirectoryDecide(cachedJson: cachedRaw, fetchedJson: raw)
        switch decision.action {
        case .adopt:
            failures = 0
            let fetchedAt = nowMs()
            if let raw { writeCache(raw: raw, fetchedAt: fetchedAt); cachedRaw = raw }
            lastSuccessMs = fetchedAt
            publish(origin: decision.relayServer, fresh: true, success: Date(timeIntervalSince1970: TimeInterval(fetchedAt) / 1000))
        case .keepCached, .noDirectory:
            failures = failures &+ 1
            if let why = decision.rejection { gossipError("Gossip: relay directory rejected: \(why)") }
            publish(origin: decision.relayServer, fresh: false, success: nil)
        }
    }

    private func publish(origin: String?, fresh: Bool, success: Date?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.isFresh != fresh { self.isFresh = fresh }
            // After the origin below (published first would race the transport's observer): nothing more to wait for.
            if let success { self.lastSuccess = success }
            // Only a real change reconfigures the relay; re-applying the same origin is a no-op anyway.
            if self.cachedOrigin != origin { self.cachedOrigin = origin }
            if self.awaitingFirstAnswer { self.awaitingFirstAnswer = false }
        }
    }
}
