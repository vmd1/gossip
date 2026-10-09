import Foundation
import Network
import CryptoKit
import Combine

/// Everything needed to identify + greet a peer during the Noise_IK handshake.
struct HandshakePeerInfo {
    let deviceId: String
    let deviceName: String
    let deviceType: DeviceType
    /// The peer's raw Ed25519 signing public key — see `TrustedDevice.signingPublicKeyBase64`.
    let signingPublicKey: Data
}

/// Owns the sockets to every trusted peer device simultaneously (a mesh, not a single pair) — see
/// `docs/adr/0002-device-group-addressing.md` and the mesh-support ADR.
///
/// The protocol itself lives in the Rust engine (`desktop/core`, reached only through `CoreBridge`): the Noise_IK
/// handshake and transport, framing, envelope signing/verification, de-duplication, the deliver-vs-forward decision
/// that makes multi-hop relay work, trust gating of unknown devices, heartbeats and reconciliation timing. This class
/// is the shell around it: it drives `LocalDiscovery`, opens and accepts `NWConnection`s, feeds the engine the bytes
/// that arrive, writes the bytes it returns, and turns its events into the callbacks the rest of the app uses.
///
/// Everything here runs on `queue`. That is load-bearing: the engine's Noise nonces are implicit counters, so the order
/// in which its output is written to a socket must be the order it was produced in.
final class TransportManager: ObservableObject {
    enum ConnectionState: Equatable {
        case disconnected
        case discovering
        case handshaking
        case connected(deviceId: String)
    }

    @Published private(set) var connectionState: ConnectionState = .disconnected

    /// Every currently directly-connected peer's device ID. The real
    /// multi-peer signal — `connectionState` is kept as a single-value
    /// aggregate (mirroring pre-mesh behavior) for source compatibility with
    /// existing `.sink`s that just want to know "connected to anything or not".
    ///
    /// "Directly" means over a LAN socket of our own: devices reached only through the relay are in `relayedDeviceIds`
    /// instead, so everything that needs a same-network path (screen mirroring, Universal Control) keeps gating on this
    /// set and never starts for a relayed device.
    @Published private(set) var connectedDeviceIds: Set<String> = []

    /// Devices whose only live link goes through the relay. They are connected (messages flow), but features that need
    /// the same network refuse them. Main thread.
    @Published private(set) var relayedDeviceIds: Set<String> = []

    /// The relay client's state, for Settings: "disabled", "no_topic", "disconnected", "connecting" or "joined".
    @Published private(set) var relayStatus: String = "disabled"

    /// The last hint the relay gave for why it is refusing us (`upgrade_required`, `denied`, ...), cleared on join.
    @Published private(set) var relayErrorCode: String?

    enum ConnectionPath: Equatable { case direct, relayed, none }

    /// How this Mac currently reaches `deviceId` (main thread). Direct wins over relayed.
    func connectionPath(for deviceId: String) -> ConnectionPath {
        if connectedDeviceIds.contains(deviceId) { return .direct }
        if relayedDeviceIds.contains(deviceId) { return .relayed }
        return .none
    }

    func isRelayed(_ deviceId: String) -> Bool { connectionPath(for: deviceId) == .relayed }

    /// Devices we have no direct connection to but heard from recently via the mesh
    /// (`DeviceConnectivity.meshTTL`). Main thread. Re-evaluated every 15s and on connection changes.
    @Published private(set) var meshReachableDeviceIds: Set<String> = []
    private var lastHeard: [String: Date] = [:]
    private var meshExpiryTimer: Timer?

    private func noteHeard(from senderId: String) {
        lastHeard[senderId] = Date()
        refreshMeshReachable()
    }

    private func refreshMeshReachable() {
        let reachable = DeviceConnectivity.meshReachable(
            lastHeard: lastHeard, directIds: connectedDeviceIds.union(relayedDeviceIds), selfId: identity.deviceId, now: Date()
        )
        if reachable != meshReachableDeviceIds { meshReachableDeviceIds = reachable }
    }

    /// Fired for every successfully decoded, post-handshake envelope this
    /// device is the intended recipient of (directly addressed, or broadcast).
    /// Not fired for envelopes merely being relayed through this device. For an
    /// envelope with `hasRawFollowup: true`, this fires only once the raw frame
    /// that follows it has actually arrived (see `onRawFrameReceived`) — never
    /// with the metadata alone.
    var onReceive: ((Envelope) -> Void)?

    /// Fired alongside `onReceive`/`router.route`, but only for an envelope whose
    /// `hasRawFollowup` is `true`, once its raw binary frame has arrived — pairs the
    /// metadata `Envelope` with the raw `Data` so a feature manager (e.g.
    /// `ClipboardSyncManager` for image sync) can consume both together. See
    /// `docs/wire-protocol.md`'s "Large binary payloads" section.
    var onRawFrameReceived: ((Envelope, Data) -> Void)?

    /// Fired when a Noise handshake completes with a peer that is not yet in
    /// `TrustedDevicesStore`. `PairingViewModel` uses this to prompt the user
    /// to confirm + trust the new device. Returning `true` from the completion
    /// keeps the connection open; `false` tears it down.
    var onUntrustedHandshake: ((_ peer: HandshakePeerInfo, _ publicKey: Curve25519.KeyAgreement.PublicKey, _ confirm: @escaping (Bool) -> Void) -> Void)?

    /// Fired (main thread) when the connection behind an open trust prompt went away before the user answered.
    var onUntrustedPromptCancelled: (() -> Void)?

    /// Fired when a handshake completes with an already-trusted peer, i.e. a
    /// normal reconnect (or a freshly-confirmed pairing, which reaches the
    /// same "connected" outcome once the user confirms trust). Multicast
    /// (via `addOnTrustedConnected`) since both `PairingViewModel` (drives UI
    /// state) and others need to observe every connection independently.
    private var trustedConnectedHandlers: [(HandshakePeerInfo) -> Void] = []

    func addOnTrustedConnected(_ handler: @escaping (HandshakePeerInfo) -> Void) {
        trustedConnectedHandlers.append(handler)
    }

    /// Fired once a peer that was newly added to `TrustedDevicesStore` during
    /// this handshake (i.e. a brand-new pairing, not a reconnect) finishes
    /// connecting. `RosterGossipManager` uses this to broadcast the updated
    /// roster to the rest of the mesh. Multicast for the same reason as
    /// `addOnTrustedConnected`.
    private var newDevicePairedHandlers: [(HandshakePeerInfo) -> Void] = []

    func addOnNewDevicePaired(_ handler: @escaping (HandshakePeerInfo) -> Void) {
        newDevicePairedHandlers.append(handler)
    }

    let router = MessageRouter()

    /// Per-device feature toggles: a disabled feature's messages are neither sent nor delivered (see `FeatureSettings`).
    /// The engine applies the same gate, so changes are pushed to it.
    var featureSettings: FeatureSettings = .shared {
        didSet { observeFeatureSettings(); pushFeatureSettings() }
    }
    private var featureSettingsObserver: AnyCancellable?

    private let discovery = LocalDiscovery()
    private let identity: IdentityKeyStore
    private let trustedDevices: TrustedDevicesStore
    private let relaySettings: RelaySettings
    private let topicStore: RelayTopicStore
    let relayDirectory: RelayDirectoryService
    private var relaySettingsObserver: AnyCancellable?
    private var relayDirectoryObserver: AnyCancellable?
    /// Actions produced while loading the persisted topic, executed with the first tick.
    private var startupActions: [CoreBridge.BridgeAction] = []
    private var relayConnection: RelayConnection?
    private var relayGeneration = 0

    /// The Rust engine, behind its bridge. Created on first use (not in `init`) because building it reads this device's
    /// identity from the Keychain; many tests construct a `TransportManager` only to use its router, and constructing
    /// one must stay free of side effects. Only touched on `queue`.
    private var engine: CoreBridge?
    private var bridge: CoreBridge {
        if let engine { return engine }
        let created: CoreBridge
        do {
            created = try CoreBridge(
                identity: identity, deviceName: Host.current().localizedName ?? "Mac",
                trustedDevices: trustedDevices, disabledFeatures: Self.disabledFeatureKeys(featureSettings)
            )
            // Before the first tick, so the relay can join as soon as it is enabled.
            if let topic = topicStore.load() {
                startupActions += (try? created.setTopic(secret: topic.secret, epoch: topic.epoch)) ?? []
            }
        } catch {
            // The identity keys are fixed-size and the snapshot is produced by us; a failure here is a programming
            // error, not something the user can recover from.
            fatalError("Gossip: could not start the protocol engine: \(error)")
        }
        engine = created
        return created
    }

    /// One socket. While a handshake is in flight `deviceId` is `nil`; the engine tells us who it is on promotion.
    private final class Link {
        let conn: UInt64
        let connection: NWConnection
        /// Set for connections this side dialed.
        let dialTarget: String?
        /// Set once the engine has promoted the connection to a live peer.
        var deviceId: String?
        /// Whether the engine has been told about this connection yet (inbound: at accept, outbound: when it is ready).
        var engineAware = false
        var peerIPAddress: String?
        /// Same host as `peerIPAddress` but with any `%zone` kept — needed to dial IPv6 link-local peers.
        var peerHostWithZone: String?

        init(conn: UInt64, connection: NWConnection, dialTarget: String?) {
            self.conn = conn
            self.connection = connection
            self.dialTarget = dialTarget
        }
    }

    private var links: [UInt64: Link] = [:]
    private var linkByDevice: [String: UInt64] = [:]
    /// Devices with an outbound socket still connecting (before the engine's own dial guard applies).
    private var connectingTargets: Set<String> = []
    private var nextConn: UInt64 = 1

    private let queue = DispatchQueue(label: "dev.vmd1.gossip.transportmanager")
    private static let queueKey = DispatchSpecificKey<Void>()

    init(trustedDevices: TrustedDevicesStore = .shared, identity: IdentityKeyStore = .shared,
         relaySettings: RelaySettings = .shared, topicStore: RelayTopicStore = .shared,
         relayDirectory: RelayDirectoryService = .shared) {
        self.trustedDevices = trustedDevices
        self.identity = identity
        self.relaySettings = relaySettings
        self.topicStore = topicStore
        self.relayDirectory = relayDirectory
        queue.setSpecific(key: Self.queueKey, value: ())
        observeFeatureSettings()
        observeRelaySettings()
    }

    private func observeRelaySettings() {
        relaySettingsObserver = Publishers.Merge(
            relaySettings.$enabled.map { _ in () }, relaySettings.$customURL.map { _ in () }
        )
        .dropFirst(2)
        // `@Published` emits before the value is stored; read it after the current main-thread turn.
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.applyRelaySettings() }
        // A different relay named by the directory reconfigures the relay cleanly (the engine closes the old socket and
        // reconnects); re-applying an unchanged one is a no-op.
        relayDirectoryObserver = Publishers.Merge(
            relayDirectory.$cachedOrigin.map { _ in () }, relayDirectory.$awaitingFirstAnswer.map { _ in () }
        )
            .dropFirst(2)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyRelaySettings() }
    }

    /// Pushes the user's relay preferences to the engine. The relay is the custom address if set, else the one the relay
    /// directory names, else the built-in default; an invalid custom address leaves the relay off. The directory is
    /// polled only while the relay is switched on.
    func applyRelaySettings() {
        let configuration = relaySettings.configuration(directoryOrigin: relayDirectory.cachedOrigin, directoryIsFresh: relayDirectory.isFresh,
                                                          awaitingDirectory: relayDirectory.awaitingFirstAnswer)
        relayDirectory.setActive(relaySettings.enabled && configuration.resolution != nil)
        setRelayEnabled(configuration.enabled, origin: configuration.origin)
    }

    /// Turns the relay on or off. `origin` is the normalized `wss://host[:port]` (`RelayEndpointPolicy`); enabling
    /// without one is the same as disabling.
    func setRelayEnabled(_ enabled: Bool, origin: String?) {
        queue.async { [weak self] in
            guard let self, self.engine != nil || enabled else { return }
            self.process(self.bridge.relayConfigure(enabled: enabled && origin != nil, origin: origin ?? ""))
            self.publishRelayStatus()
        }
    }

    /// Test hook: how long a trusted peer must have had no live link before it is dialed through the relay.
    func setLanGraceMs(_ ms: Int64) {
        queue.async { [weak self] in self?.bridge.setLanGraceMs(ms) }
    }

    private static func disabledFeatureKeys(_ settings: FeatureSettings) -> [String] {
        Feature.allCases.filter { !settings.isEnabled($0) }.map(\.rawValue)
    }

    private func observeFeatureSettings() {
        featureSettingsObserver = featureSettings.objectWillChange.sink { [weak self] _ in
            // `objectWillChange` fires before the value changes; read after the current main-thread turn.
            DispatchQueue.main.async { self?.pushFeatureSettings() }
        }
    }

    private func pushFeatureSettings() {
        let keys = Self.disabledFeatureKeys(featureSettings)
        // Only if the engine exists already; otherwise it picks the current settings up when it is created.
        queue.async { [weak self] in self?.engine?.setDisabledFeatures(keys) }
    }

    /// Every piece of connection state (`links`, `linkByDevice`, `connectingTargets`, the engine) is owned by `queue`.
    /// Entry points that can be called from the main thread (UI, timers, feature managers) go through this so they
    /// never touch that state concurrently with the `NWConnection` callbacks.
    private func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil { return try body() }
        return try queue.sync(execute: body)
    }

    /// Matches Android's `TransportManager.DEFAULT_PORT`. Used (rather than an ephemeral
    /// Bonjour-assigned port) so Android's manual fallback-address dial — for reaching a
    /// paired Mac that isn't visible over local mDNS, e.g. over a Tailscale IP — has a
    /// fixed, known port to connect to. On-LAN discovery still works exactly as before;
    /// Bonjour resolves the actual port from the advertisement either way.
    static let defaultPort: NWEndpoint.Port = 7913

    // MARK: - Lifecycle

    /// True once `start()` has set up advertising/browsing, so repeated calls
    /// (the menu bar dropdown's `.onAppear` fires on every open, and
    /// `PairingViewModel` also calls this when pairing begins) are no-ops
    /// instead of each spinning up a brand-new `NWListener` on a fresh
    /// ephemeral port — which left the previous listener's port stale
    /// everywhere it had already been advertised/discovered.
    private var hasStarted = false
    private var redialTimer: Timer?
    private var engineTimer: DispatchSourceTimer?
    private static let redialInterval: TimeInterval = 10

    /// Starts advertising this Mac on the local network and browsing for
    /// peers. Automatically dials every discovered peer that is already
    /// trusted and not already connected/connecting.
    /// Safe to call repeatedly — only the first call has any effect.
    ///
    /// - Parameter lan: `false` skips Bonjour and the TCP listener (the engine clock and the relay still run); only the
    ///   relay end-to-end test uses it.
    func start(deviceName: String = Host.current().localizedName ?? "Mac", lan: Bool = true) {
        guard !hasStarted else { return }
        hasStarted = true
        onQueue { recomputeConnectionState() }
        if lan { startLAN(deviceName: deviceName) }
        startEngineClock()
        applyRelaySettings()
    }

    private func startLAN(deviceName: String) {

        discovery.onIncomingConnection = { [weak self] connection in
            self?.queue.async { self?.accept(connection: connection) }
        }
        discovery.onPeersChanged = { [weak self] peers in
            self?.queue.async { self?.handleDiscoveredPeers(peers) }
        }

        do {
            try discovery.startAdvertising(
                deviceId: identity.deviceId,
                deviceName: deviceName,
                publicKeyFingerprint: identity.publicKeyFingerprint,
                port: Self.defaultPort
            )
        } catch {
            // Most likely cause: another local process already holds the fixed port
            // (e.g. a second Connect instance during development). Fall back to an
            // ephemeral port so on-LAN pairing/discovery still works — only the
            // fallback-address dial path from Android needs the fixed port.
            gossipError("Gossip: failed to advertise on fixed port \(Self.defaultPort), falling back to an ephemeral port: \(error)")
            do {
                try discovery.startAdvertising(
                    deviceId: identity.deviceId,
                    deviceName: deviceName,
                    publicKeyFingerprint: identity.publicKeyFingerprint
                )
            } catch {
                gossipError("Gossip: failed to start advertising: \(error)")
            }
        }
        discovery.startBrowsing()

        meshExpiryTimer?.invalidate()
        meshExpiryTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refreshMeshReachable()
        }

        // Self-healing redial: a peer that drops while its Bonjour advertisement stays visible produces
        // no new browse result, so nothing would ever dial it again. Re-offer the visible peers
        // periodically; `handleDiscoveredPeers` skips anything already connected or being dialled.
        redialTimer?.invalidate()
        redialTimer = Timer.scheduledTimer(withTimeInterval: Self.redialInterval, repeats: true) { [weak self] _ in
            self?.discovery.redeliverPeers()
        }

    }

    /// The engine's clock: heartbeats, stale and stuck-handshake cleanup, pairing expiry, reconciliation, and the relay's
    /// reconnect backoff.
    private func startEngineClock() {
        engineTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let startup = self.startupActions
            self.startupActions = []
            self.process(startup + self.bridge.tick())
            self.publishRelayStatus()
        }
        timer.resume()
        engineTimer = timer
    }

    func stop() {
        hasStarted = false
        redialTimer?.invalidate()
        redialTimer = nil
        engineTimer?.cancel()
        engineTimer = nil
        relayDirectory.setActive(false)
        discovery.stopAdvertising()
        discovery.stopBrowsing()
        onQueue {
            if engine != nil { process(bridge.relayConfigure(enabled: false, origin: "")) }
            closeRelayConnection()
            for conn in Array(links.keys) {
                dropLink(conn, notifyEngine: true)
            }
            connectingTargets.removeAll()
            recomputeConnectionState()
        }
    }

    private func handleDiscoveredPeers(_ discovered: [DiscoveredPeer]) {
        for candidate in discovered {
            guard let trusted = trustedDevices.device(for: candidate.deviceId),
                  let keyData = Data(base64Encoded: trusted.publicKeyBase64),
                  let staticKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyData) else { continue }
            guard bridge.shouldDial(deviceId: candidate.deviceId), !connectingTargets.contains(candidate.deviceId) else { continue }
            // Anyone on the LAN can advertise a trusted device's id; only dial an advertisement whose key
            // fingerprint matches the key we pinned, so a squatter can't tie up the per-device dial slot.
            guard Self.fingerprintMatches(candidate.publicKeyFingerprint, keyData: keyData) else { continue }
            connect(to: candidate, remoteStaticKey: staticKey)
        }
    }

    /// The two advertisement formats in use: the Mac's (base64 of the first 8 digest bytes) and Android's
    /// (first 16 characters of the unpadded base64 of the whole SHA-256 digest).
    static func fingerprintMatches(_ advertised: String, keyData: Data) -> Bool {
        let digest = Data(SHA256.hash(data: keyData))
        let macStyle = Data(digest.prefix(8)).base64EncodedString()
        let androidStyle = String(digest.base64EncodedString().replacingOccurrences(of: "=", with: "").prefix(16))
        return advertised == macStyle || advertised == androidStyle
    }

    // MARK: - Outbound connection (initiator role)

    /// Dials a discovered peer as the Noise_IK initiator. `remoteStaticKey`
    /// must be known ahead of time: either from `TrustedDevicesStore` (a
    /// reconnect) or from a freshly-scanned pairing QR code (first connect).
    func connect(to peer: DiscoveredPeer, remoteStaticKey: Curve25519.KeyAgreement.PublicKey) {
        onQueue { dial(deviceId: peer.deviceId, endpoint: peer.endpoint, remoteStaticKey: remoteStaticKey) }
    }

    /// Dials a manually-configured fallback address (e.g. a Tailscale IP) directly,
    /// bypassing Bonjour discovery entirely — the Mac-side counterpart to Android's
    /// `SyncForegroundService.runFallbackDialLoop`. Both sides normally rely on
    /// LAN-only discovery (Mac browses, Android just listens); this is what makes
    /// reconnecting possible at all once the two devices aren't on the same LAN/mDNS
    /// domain. See `TrustedDevice.fallbackHost` and `docs/wire-protocol.md`.
    func connect(toFallbackHost host: String, port: NWEndpoint.Port = TransportManager.defaultPort,
                 remoteStaticKey: Curve25519.KeyAgreement.PublicKey, deviceId: String) {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)
        onQueue { dial(deviceId: deviceId, endpoint: endpoint, remoteStaticKey: remoteStaticKey) }
    }

    /// The TCP port this device is listening on once `start()` has brought the listener up (the fixed default port, or
    /// an ephemeral one if another process already held it). `nil` before that.
    var listeningPort: UInt16? { discovery.advertisedPort?.rawValue }

    private func dial(deviceId: String, endpoint: NWEndpoint, remoteStaticKey: Curve25519.KeyAgreement.PublicKey) {
        guard bridge.shouldDial(deviceId: deviceId), !connectingTargets.contains(deviceId) else { return }
        connectingTargets.insert(deviceId)

        let connection = NWConnection(to: endpoint, using: .tcp)
        let link = Link(conn: allocateConn(), connection: connection, dialTarget: deviceId)
        links[link.conn] = link
        recomputeConnectionState()

        connection.stateUpdateHandler = { [weak self] state in
            self?.handleOutboundState(state, link: link, remoteStaticKey: remoteStaticKey)
        }
        connection.start(queue: queue)
        scheduleConnectTimeout(for: link)
    }

    private func allocateConn() -> UInt64 {
        defer { nextConn += 1 }
        return nextConn
    }

    private func handleOutboundState(_ state: NWConnection.State, link: Link, remoteStaticKey: Curve25519.KeyAgreement.PublicKey) {
        guard links[link.conn] === link else { return }
        switch state {
        case .ready:
            guard !link.engineAware else { return }
            link.engineAware = true
            resolvePeerIPAddress(link)
            if let target = link.dialTarget { connectingTargets.remove(target) }
            do {
                process(try bridge.dial(conn: link.conn, target: link.dialTarget ?? "", remoteStaticKey: remoteStaticKey.rawRepresentation))
            } catch {
                gossipError("Gossip: could not start the handshake with \(link.dialTarget ?? "peer"): \(error)")
                dropLink(link.conn, notifyEngine: false)
                return
            }
            startReceiveLoop(link)
        case .failed(let error):
            gossipError("Gossip: connection failed: \(error)")
            dropLink(link.conn, notifyEngine: true)
        default:
            break
        }
    }

    /// Guards against a dial that never resolves either way — most notably `NWConnection`'s `.waiting(NWError)`
    /// state, which Apple documents as "may attempt to connect again after changes" and which can also persist
    /// indefinitely on a genuinely unreachable peer (phone in aggressive Doze, its service killed). Without this the
    /// per-device dial slot would stay taken and the peer could never be retried. Once the TCP connection is ready
    /// the engine's own handshake timeout takes over.
    private func scheduleConnectTimeout(for link: Link) {
        queue.asyncAfter(deadline: .now() + Self.connectTimeout) { [weak self] in
            guard let self, self.links[link.conn] === link, !link.engineAware else { return }
            gossipError("Gossip: connecting to \(link.dialTarget ?? "peer") timed out after \(Self.connectTimeout)s; giving up")
            self.dropLink(link.conn, notifyEngine: false)
        }
    }

    private static let connectTimeout: TimeInterval = 15

    /// Caps on simultaneously pending (not yet handshaken) inbound connections, overall and per source IP.
    static let maxPendingInbound = 32
    static let maxPendingInboundPerHost = 4

    // MARK: - Pairing gate

    /// While a pairing QR is on screen, an untrusted peer presenting its token may be offered to the user (single use,
    /// expires after five minutes — enforced by the engine).
    func armPairing(token: String) {
        queue.async { [weak self] in self?.bridge.armPairing(token: token) }
    }

    func disarmPairing() {
        queue.async { [weak self] in self?.bridge.disarmPairing() }
    }

    // MARK: - Inbound connection (responder role)

    private func accept(connection: NWConnection) {
        let host = Self.hostString(of: connection.endpoint)
        let pendingInbound = links.values.filter { $0.deviceId == nil && $0.dialTarget == nil }
        if pendingInbound.count >= Self.maxPendingInbound
            || (host != nil && pendingInbound.filter { Self.hostString(of: $0.connection.endpoint) == host }.count >= Self.maxPendingInboundPerHost) {
            gossipError("Gossip: too many pending inbound connections; refusing one")
            connection.cancel()
            return
        }
        let link = Link(conn: allocateConn(), connection: connection, dialTarget: nil)
        links[link.conn] = link
        do {
            process(try bridge.accepted(conn: link.conn))
        } catch {
            gossipError("Gossip: could not accept a connection: \(error)")
            links.removeValue(forKey: link.conn)
            connection.cancel()
            return
        }
        link.engineAware = true
        recomputeConnectionState()

        connection.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                gossipError("Gossip: inbound connection failed: \(error)")
                self?.dropLink(link.conn, notifyEngine: true)
            }
        }
        connection.start(queue: queue)
        resolvePeerIPAddress(link)
        startReceiveLoop(link)
    }

    private static func hostString(of endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        guard let bare = "\(host)".split(separator: "%").first.map(String.init) else { return nil }
        // IPv6 peers are limited per /64: one host can own billions of addresses in its prefix.
        var addr = in6_addr()
        if inet_pton(AF_INET6, bare, &addr) == 1 {
            return withUnsafeBytes(of: &addr) { Data($0.prefix(8)).map { String(format: "%02x", $0) }.joined() }
        }
        return bare
    }

    /// Extracts the remote endpoint's bare IP address (stripping any zone
    /// ID like `%en0`) from an `NWConnection`'s current path, for both the
    /// initiator (dials an already-resolved `.hostPort`/IP endpoint) and
    /// responder (inbound connection; the remote endpoint is populated by
    /// the time the connection is ready/accepted) roles.
    private func resolvePeerIPAddress(_ link: Link) {
        guard let remote = link.connection.currentPath?.remoteEndpoint ?? link.connection.endpoint as NWEndpoint? else { return }
        if case .hostPort(let host, _) = remote {
            let ipString = "\(host)"
            link.peerHostWithZone = ipString
            link.peerIPAddress = ipString.split(separator: "%").first.map(String.init) ?? ipString
        }
    }

    func ipAddress(for deviceId: String) -> String? {
        onQueue { linkByDevice[deviceId].flatMap { links[$0] }?.peerIPAddress }
    }

    /// Like `ipAddress(for:)` but keeps an IPv6 `%zone` (e.g. `fe80::1%en0`), which a plain
    /// `NWConnection` to a link-local peer needs. Used to dial the screen bridge's WebSocket.
    func hostWithZone(for deviceId: String) -> String? {
        onQueue {
            let link = linkByDevice[deviceId].flatMap { links[$0] }
            return link?.peerHostWithZone ?? link?.peerIPAddress
        }
    }

    /// Tears down the live connection to one specific peer, if any (e.g. after
    /// `trust.revoke`) — leaves every other peer untouched.
    func disconnect(deviceId: String) {
        onQueue { process(bridge.disconnect(deviceId: deviceId)) }
    }

    // MARK: - Receiving

    private func startReceiveLoop(_ link: Link) {
        link.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, self.links[link.conn] === link else { return }
            if let data, !data.isEmpty {
                self.process(self.bridge.bytesReceived(conn: link.conn, data))
            }
            // The engine may have closed this connection while handling the bytes.
            guard self.links[link.conn] === link else { return }
            if let error {
                gossipError("Gossip: receive error: \(error)")
                self.dropLink(link.conn, notifyEngine: true)
                return
            }
            if isComplete {
                self.dropLink(link.conn, notifyEngine: true)
                return
            }
            self.startReceiveLoop(link)
        }
    }

    // MARK: - Carrying out what the engine decided

    /// Executes the engine's output in order. Must be called on `queue`.
    private func process(_ actions: [CoreBridge.BridgeAction]) {
        // Noise nonces are implicit counters, so bytes must reach the socket in the order the engine encrypted them.
        // Handlers run below may call back into the engine (and encrypt more frames), so every write from this batch
        // goes out first.
        for action in actions {
            switch action {
            case .send(let conn, let bytes):
                guard let link = links[conn] else { continue }
                link.connection.send(content: bytes, completion: .contentProcessed { error in
                    if let error { gossipError("Gossip: send failed: \(error)") }
                })
            case .relaySendText(let text): relayConnection?.sendText(text)
            case .relaySendBinary(let bytes): relayConnection?.sendBinary(bytes)
            default: break
            }
        }
        for action in actions {
            switch action {
            case .send, .relaySendText, .relaySendBinary:
                break

            case .relayConnect(let url): openRelayConnection(url: url)

            case .relayClose: closeRelayConnection()

            case .relayJoined:
                DispatchQueue.main.async { [weak self] in self?.relayErrorCode = nil }

            case .relayDown:
                break // the status line follows `relay_status`, published after this batch

            case .relayError(let code):
                gossipError("Gossip: relay refused: \(code)")
                DispatchQueue.main.async { [weak self] in self?.relayErrorCode = code }

            case .topicChanged(let secret, let epoch):
                if !topicStore.save(secret: secret, epoch: epoch) { gossipError("Gossip: could not persist the relay topic") }

            case .close(let conn):
                dropLink(conn, notifyEngine: false)

            case .peerConnected(let conn, let peer, let newlyPaired):
                if let link = links[conn] {
                    link.deviceId = peer.deviceId
                    linkByDevice[peer.deviceId] = conn
                }
                recomputeConnectionState(preferring: peer.deviceId)
                trustedConnectedHandlers.forEach { $0(peer) }
                if newlyPaired { newDevicePairedHandlers.forEach { $0(peer) } }

            case .peerDisconnected(let deviceId):
                if let conn = linkByDevice[deviceId], links[conn] == nil || links[conn]?.deviceId == deviceId {
                    linkByDevice.removeValue(forKey: deviceId)
                }
                recomputeConnectionState()

            case .pairingPrompt(let conn, let peer, let publicKey):
                guard let handler = onUntrustedHandshake else {
                    // No pairing UI registered to confirm trust; refuse rather than silently stay connected.
                    process(bridge.confirmPairing(conn: conn, accepted: false))
                    continue
                }
                handler(peer, publicKey) { [weak self] confirmed in
                    // The UI answers on the main thread; the engine and the sockets live on `queue`.
                    self?.queue.async { [weak self] in
                        guard let self else { return }
                        self.process(self.bridge.confirmPairing(conn: conn, accepted: confirmed))
                    }
                }

            case .pairingPromptCancelled:
                DispatchQueue.main.async { [weak self] in self?.onUntrustedPromptCancelled?() }

            case .deliver(let envelope, let raw):
                router.route(envelope)
                DispatchQueue.main.async { [weak self] in
                    self?.onReceive?(envelope)
                    if let raw { self?.onRawFrameReceived?(envelope, raw) }
                }

            case .heard(let deviceId):
                DispatchQueue.main.async { [weak self] in self?.noteHeard(from: deviceId) }

            case .trustChanged(let json):
                trustedDevices.importCoreSnapshot(json)

            case .deviceRevoked:
                break // the trust snapshot that accompanies it already updated the store

            case .reconcileDue(let task, let peer):
                // Only trust gossip is scheduled by the engine for now; each feature still runs its own resync timer.
                if task == "trust.roster_update" { sendRoster(to: peer) }
            }
        }
        publishRelayStatus()
    }

    // MARK: - Relay socket

    private func openRelayConnection(url urlString: String) {
        closeRelayConnection()
        guard let url = RelayEndpointPolicy.validateConnectURL(urlString, customURL: relaySettings.customURL) else {
            // Never connect to an address the policy does not allow; the engine treats this as a failed connect and backs off.
            gossipError("Gossip: refusing to connect to a relay address that is not allowed")
            process(bridge.relaySocketClosed())
            return
        }
        relayGeneration += 1
        let generation = relayGeneration
        var everOpened = false
        relayConnection = RelayConnection(
            url: url, queue: queue,
            onOpen: { [weak self] in
                guard let self, self.relayGeneration == generation else { return }
                everOpened = true
                self.process(self.bridge.relaySocketOpened())
            },
            onText: { [weak self] text in
                guard let self, self.relayGeneration == generation else { return }
                self.process(self.bridge.relayTextReceived(text))
            },
            onBinary: { [weak self] data in
                guard let self, self.relayGeneration == generation else { return }
                self.process(self.bridge.relayBinaryReceived(data))
            },
            onClosed: { [weak self] in
                guard let self, self.relayGeneration == generation else { return }
                self.relayConnection = nil
                // A socket that never opened is a connect failure: the relay may have moved, so ask the directory.
                if !everOpened { self.relayDirectory.noteRelayConnectFailure() }
                self.process(self.bridge.relaySocketClosed())
            }
        )
    }

    /// Closes the relay socket without reporting it back (the engine asked for it, or we are shutting down).
    private func closeRelayConnection() {
        relayGeneration += 1
        relayConnection?.close()
        relayConnection = nil
    }

    private var lastPublishedRelayStatus = "disabled"

    /// Mirrors the engine's relay status and which devices are relayed into the published state. Must be called on `queue`.
    private func publishRelayStatus() {
        guard let engine else { return }
        let status = engine.relayStatus()
        guard status != lastPublishedRelayStatus else { return }
        lastPublishedRelayStatus = status
        DispatchQueue.main.async { [weak self] in self?.relayStatus = status }
    }

    /// Removes a socket. `notifyEngine` is false when the engine itself asked for the close (it has already forgotten it).
    private func dropLink(_ conn: UInt64, notifyEngine: Bool) {
        guard let link = links.removeValue(forKey: conn) else { return }
        link.connection.stateUpdateHandler = nil
        link.connection.cancel()
        if let target = link.dialTarget { connectingTargets.remove(target) }
        if let deviceId = link.deviceId, linkByDevice[deviceId] == conn { linkByDevice.removeValue(forKey: deviceId) }
        if notifyEngine { process(bridge.connectionClosed(conn: conn)) }
        recomputeConnectionState()
    }

    private func recomputeConnectionState(preferring preferredDeviceId: String? = nil) {
        let ids = Set(linkByDevice.keys)
        // Peers the engine reports as connected that have no socket of ours are reached through the relay.
        let relayed = Set(engine?.connectedPeers().filter { !ids.contains($0) && engine?.isRelayed(deviceId: $0) == true } ?? [])
        let reachable = ids.union(relayed)
        let newState: ConnectionState
        if let preferredDeviceId, reachable.contains(preferredDeviceId) {
            newState = .connected(deviceId: preferredDeviceId)
        } else if let any = ids.first ?? relayed.first {
            newState = .connected(deviceId: any)
        } else if !links.isEmpty {
            newState = .handshaking
        } else if hasStarted {
            newState = .discovering
        } else {
            newState = .disconnected
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.connectedDeviceIds = ids
            self.relayedDeviceIds = relayed
            self.connectionState = newState
            self.refreshMeshReachable()
        }
    }

    // MARK: - Sending application envelopes

    enum SendError: Error { case notConnected, tooLarge, failed(String) }

    /// Signs (if locally originated), records and sends `envelope` toward everyone it addresses: a broadcast goes to
    /// every connected peer, a `recipientId` we are directly connected to goes there, and one we are not is flooded to
    /// every peer so it can find a multi-hop path. A message for a feature turned off on this device is silently
    /// skipped. Throws `notConnected` when there is nobody to send it to.
    func send(envelope: Envelope) throws {
        guard featureSettings.isMessageAllowed(type: envelope.type) else { return }
        try onQueue { process(try sendThroughEngine { try bridge.send(envelope) }) }
    }

    /// Originates a `hasRawFollowup` envelope + its raw binary frame (e.g. clipboard image sync); the raw frame's hash is
    /// bound into the signed payload by the engine. Devices with no direct connection to the target receive it via the
    /// relays, which forward the pair atomically.
    func send(_ envelope: Envelope, withRawFollowup rawData: Data) throws {
        guard featureSettings.isMessageAllowed(type: envelope.type) else { return }
        try onQueue { process(try sendThroughEngine { try bridge.send(envelope, raw: rawData) }) }
    }

    private func sendThroughEngine(_ body: () throws -> [CoreBridge.BridgeAction]) throws -> [CoreBridge.BridgeAction] {
        do {
            return try body()
        } catch CoreBridge.BridgeError.notConnected {
            throw SendError.notConnected
        } catch CoreBridge.BridgeError.tooLarge {
            throw SendError.tooLarge
        } catch {
            throw SendError.failed("\(error)")
        }
    }

    func sendPresence(online: Bool) {
        let envelope = Envelope(
            type: online ? "presence.online" : "presence.offline",
            senderId: identity.deviceId,
            broadcast: true
        )
        try? send(envelope: envelope)
    }

    // MARK: - Trust gossip (driven by the engine's reconciliation schedule)

    /// Sends this device's roster to `peer`, or broadcasts it to the whole mesh when `peer` is `nil`.
    func sendRoster(to peer: String?) {
        onQueue { process((try? sendThroughEngine { try bridge.send(bridge.rosterUpdate(peer: peer)) }) ?? []) }
    }

    /// The user removed a device: the engine drops its trust and connection and broadcasts `trust.revoke` to the mesh.
    func revokeDevice(_ deviceId: String) {
        onQueue { process(bridge.revokeDevice(deviceId: deviceId)) }
    }
}
