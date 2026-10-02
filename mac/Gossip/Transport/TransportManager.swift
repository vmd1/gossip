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

/// Owns the connection lifecycle to every trusted peer device simultaneously
/// (a mesh, not a single pair) — see `docs/adr/0002-device-group-addressing.md`
/// and the mesh-support ADR. Drives `LocalDiscovery` to find/advertise, opens
/// a raw `NWConnection` per peer, performs the Noise_IK handshake via
/// `NoiseSession`, and once connected frames/deframes `Envelope`s per the wire
/// protocol. Also makes the deliver-vs-forward decision for every received
/// envelope (see `handleReceivedEnvelope`), which is what makes multi-hop
/// relay and roster-gossip broadcast actually reach devices this Mac has no
/// direct connection to.
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
    @Published private(set) var connectedDeviceIds: Set<String> = []

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
            lastHeard: lastHeard, directIds: connectedDeviceIds, selfId: identity.deviceId, now: Date()
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

    /// Fired when a handshake completes with an already-trusted peer, i.e. a
    /// normal reconnect (or a freshly-confirmed pairing, which reaches the
    /// same "connected" outcome once the user confirms trust). Multicast
    /// (via `addOnTrustedConnected`) since both `PairingViewModel` (drives UI
    /// state) and `RosterGossipManager` (sends the new peer this Mac's
    /// roster) need to observe every connection independently.
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
    /// Per-device feature toggles: sends for a disabled feature are silently skipped (see `FeatureSettings`).
    var featureSettings: FeatureSettings = .shared

    private let discovery = LocalDiscovery()
    private let identity = IdentityKeyStore.shared
    private let trustedDevices: TrustedDevicesStore

    /// A single live or in-progress connection to one peer. Used both while a
    /// handshake is still in flight (before the remote `deviceId` is known —
    /// tracked in `pendingByObjectId`) and once established (promoted into
    /// `peers`, keyed by `deviceId`).
    private final class PeerConnection {
        var deviceId: String?
        let connection: NWConnection
        var noiseSession: NoiseSession
        var receiveBuffer = Data()
        var pendingPeer: HandshakePeerInfo?
        var expectedRemoteStaticKey: Curve25519.KeyAgreement.PublicKey?
        /// Set only for outbound dials, so teardown can clear `dialingDeviceIds`.
        var dialTargetDeviceId: String?
        var peerIPAddress: String?
        /// Same host as `peerIPAddress` but with any `%zone` kept — needed to dial IPv6 link-local peers.
        var peerHostWithZone: String?
        /// Updated on every successfully-decrypted frame (any type, not just
        /// heartbeats) — see `startHeartbeatMonitoring`'s doc for why this exists.
        var lastReceivedAt: Date = .distantPast
        var heartbeatTimer: Timer?
        /// Transport frames received while the handshake is finished but the peer is
        /// still awaiting the user's trust confirmation (so `deviceId` is nil). The
        /// initiator treats the connection as live once it reads `handshake.ack` and
        /// immediately sends its roster/initial syncs. Noise nonces are implicit
        /// counters, so dropping those frames undecrypted would desync the session for
        /// good; they're held here and decrypted in order at promotion.
        var queuedFrames = PendingFrameQueue()
        /// Serializes every `session.encrypt(...)` + `sendFramed(...)` pair for
        /// *this* peer's Noise session. `NoiseCipherState`'s nonce counter is
        /// mutable, unsynchronized state — concurrent encrypts on the same
        /// session race the nonce, and the receiver's AEAD nonce only advances
        /// on a successful decrypt, so one corrupted frame permanently desyncs
        /// the cipher for the rest of the connection. Per-peer (not global)
        /// now that there can be more than one session.
        let sendQueue = DispatchQueue(label: "dev.vmd1.gossip.transportmanager.send")

        init(connection: NWConnection, noiseSession: NoiseSession) {
            self.connection = connection
            self.noiseSession = noiseSession
        }
    }

    /// Established connections, keyed by the remote device's stable UUID.
    private var peers: [String: PeerConnection] = [:]
    /// In-flight connections (dialed or accepted) whose remote `deviceId`
    /// isn't known yet — resolved once handshake message 1/2 identifies the
    /// peer, at which point the entry moves into `peers`.
    private var pendingByObjectId: [ObjectIdentifier: PeerConnection] = [:]
    /// Device IDs currently being dialed (outbound only), so repeated Bonjour
    /// `onPeersChanged` callbacks don't redial a peer whose handshake is
    /// already in progress.
    private var dialingDeviceIds: Set<String> = []

    private let queue = DispatchQueue(label: "dev.vmd1.gossip.transportmanager")

    /// Bounded, size-capped cache of recently-seen envelope IDs, used to avoid
    /// re-forwarding/re-delivering the same broadcast or relayed message twice
    /// when the mesh has more than one path between two devices. Guarded by
    /// its own queue (not `queue`, which is the NWConnection callback queue —
    /// forwarding runs on `queue` and must not deadlock re-entering it).
    private let dedupeQueue = DispatchQueue(label: "dev.vmd1.gossip.transportmanager.dedupe")
    private var recentEnvelopeIds: [String] = []
    private var recentEnvelopeIdSet: Set<String> = []
    private static let dedupeCacheLimit = 512

    init(trustedDevices: TrustedDevicesStore = .shared) {
        self.trustedDevices = trustedDevices
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
    private static let redialInterval: TimeInterval = 10

    /// Starts advertising this Mac on the local network and browsing for
    /// peers. Automatically dials every discovered peer that is already
    /// trusted and not already connected/connecting.
    /// Safe to call repeatedly — only the first call has any effect.
    func start(deviceName: String = Host.current().localizedName ?? "Mac") {
        guard !hasStarted else { return }
        hasStarted = true
        recomputeConnectionState()

        discovery.onIncomingConnection = { [weak self] connection in
            self?.accept(connection: connection)
        }
        discovery.onPeersChanged = { [weak self] peers in
            self?.handleDiscoveredPeers(peers)
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
            NSLog("Gossip: failed to advertise on fixed port \(Self.defaultPort), falling back to an ephemeral port: \(error)")
            do {
                try discovery.startAdvertising(
                    deviceId: identity.deviceId,
                    deviceName: deviceName,
                    publicKeyFingerprint: identity.publicKeyFingerprint
                )
            } catch {
                NSLog("Gossip: failed to start advertising: \(error)")
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

    func stop() {
        hasStarted = false
        redialTimer?.invalidate()
        redialTimer = nil
        discovery.stopAdvertising()
        discovery.stopBrowsing()
        for (deviceId, peer) in peers {
            teardown(peer: peer, deviceId: deviceId)
        }
        for (_, pending) in pendingByObjectId {
            teardownPending(pending)
        }
        recomputeConnectionState()
    }

    private func handleDiscoveredPeers(_ discovered: [DiscoveredPeer]) {
        for candidate in discovered {
            guard trustedDevices.isTrusted(deviceId: candidate.deviceId) else { continue }
            guard peers[candidate.deviceId] == nil, !dialingDeviceIds.contains(candidate.deviceId) else { continue }
            guard let trusted = trustedDevices.device(for: candidate.deviceId),
                  let keyData = Data(base64Encoded: trusted.publicKeyBase64),
                  let staticKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyData) else { continue }
            connect(to: candidate, remoteStaticKey: staticKey)
        }
    }

    // MARK: - Outbound connection (initiator role)

    /// Dials a discovered peer as the Noise_IK initiator. `remoteStaticKey`
    /// must be known ahead of time: either from `TrustedDevicesStore` (a
    /// reconnect) or from a freshly-scanned pairing QR code (first connect).
    func connect(to peer: DiscoveredPeer, remoteStaticKey: Curve25519.KeyAgreement.PublicKey) {
        dial(deviceId: peer.deviceId, endpoint: peer.endpoint, remoteStaticKey: remoteStaticKey)
    }

    /// Dials a manually-configured fallback address (e.g. a Tailscale IP) directly,
    /// bypassing Bonjour discovery entirely — the Mac-side counterpart to Android's
    /// `SyncForegroundService.runFallbackDialLoop`. Both sides normally rely on
    /// LAN-only discovery (Mac browses, Android just listens); this is what makes
    /// reconnecting possible at all once the two devices aren't on the same LAN/mDNS
    /// domain. See `TrustedDevice.fallbackHost` and `docs/wire-protocol.md`.
    func connect(toFallbackHost host: String, remoteStaticKey: Curve25519.KeyAgreement.PublicKey, deviceId: String) {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: Self.defaultPort)
        dial(deviceId: deviceId, endpoint: endpoint, remoteStaticKey: remoteStaticKey)
    }

    private func dial(deviceId: String, endpoint: NWEndpoint, remoteStaticKey: Curve25519.KeyAgreement.PublicKey) {
        guard peers[deviceId] == nil, !dialingDeviceIds.contains(deviceId) else { return }
        dialingDeviceIds.insert(deviceId)

        let session = NoiseSession(
            role: .initiator,
            localStaticKey: identity.agreementKey,
            remoteStaticKey: remoteStaticKey
        )

        let nwConnection = NWConnection(to: endpoint, using: .tcp)
        let pending = PeerConnection(connection: nwConnection, noiseSession: session)
        pending.expectedRemoteStaticKey = remoteStaticKey
        pending.dialTargetDeviceId = deviceId
        pendingByObjectId[ObjectIdentifier(nwConnection)] = pending
        recomputeConnectionState()

        nwConnection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState(state, pending: pending)
        }
        nwConnection.start(queue: queue)
        scheduleTimeout(for: pending)
    }

    /// Guards against a dial or handshake that never resolves either way — most
    /// notably `NWConnection`'s `.waiting(NWError)` state, which the switch in
    /// `handleConnectionState` deliberately doesn't treat as failure (Apple's own
    /// docs: "the connection cannot currently be completed... but may attempt to
    /// connect again after changes", and it commonly *does* self-heal once the
    /// network path recovers) but which can also persist indefinitely on a
    /// genuinely unreachable peer (phone locked into aggressive Doze, its
    /// foreground service killed, etc.) — observed directly as the Android app
    /// looking permanently "stuck" on its discovering/disconnected state, because
    /// this Mac's `dialingDeviceIds`/`pendingByObjectId` entry for it never clears,
    /// which blocks `handleDiscoveredPeers` from ever retrying that same device.
    /// A hung handshake read (peer accepts the TCP connection but never completes
    /// Noise) has the same failure mode and is covered by the same timeout, since
    /// nothing here distinguishes "still connecting" from "still handshaking".
    private func scheduleTimeout(for pending: PeerConnection) {
        let key = ObjectIdentifier(pending.connection)
        queue.asyncAfter(deadline: .now() + Self.pendingConnectionTimeout) { [weak self] in
            guard let self, self.pendingByObjectId[key] === pending else { return } // already resolved (either way)
            NSLog("Gossip: dial/handshake to \(pending.dialTargetDeviceId ?? "unknown peer") timed out after \(Self.pendingConnectionTimeout)s; tearing down")
            self.teardownPending(pending)
        }
    }

    private static let pendingConnectionTimeout: TimeInterval = 15

    private func handleConnectionState(_ state: NWConnection.State, pending: PeerConnection) {
        switch state {
        case .ready:
            resolvePeerIPAddress(pending)
            sendHandshakeMessage1(pending: pending)
            startReceiveLoop(pending: pending)
        case .failed(let error):
            NSLog("Gossip: connection failed: \(error)")
            teardownAny(pending)
        case .cancelled:
            break
        default:
            break
        }
    }

    /// Handshake messages travel as plaintext JSON `Envelope`s — `type: "handshake.hello"` /
    /// `"handshake.ack"` — with the raw Noise message bytes carried base64-encoded in a
    /// `noise` payload field, and device identity (`deviceName`/`deviceType`) alongside it
    /// in the envelope, per `schema/message-types.md`. The underlying Noise message itself
    /// always carries an *empty* handshake payload (device info rides in the envelope, not
    /// inside the encrypted Noise payload) — this must match the Android side exactly, since
    /// both are independently-implemented Noise state machines that only agree on wire bytes,
    /// not on Swift/Kotlin types.
    private func sendHandshakeMessage1(pending: PeerConnection) {
        guard let message = try? pending.noiseSession.createMessage1(payload: Data()) else { return }
        let envelope = Envelope(
            type: "handshake.hello",
            senderId: identity.deviceId,
            payload: .object([
                "noise": .string(message.base64EncodedString()),
                "deviceName": .string(currentDeviceName()),
                "deviceType": .string(DeviceType.mac.rawValue),
                "signingPublicKey": .string(identity.signingKey.publicKey.rawRepresentation.base64EncodedString())
            ])
        )
        guard let framed = try? envelope.encoded() else { return }
        sendFramed(framed, over: pending.connection)
    }

    // MARK: - Inbound connection (responder role)

    private func accept(connection: NWConnection) {
        // Responder doesn't know the initiator's static key yet; it's
        // learned from message 1.
        let session = NoiseSession(
            role: .responder,
            localStaticKey: identity.agreementKey,
            remoteStaticKey: nil
        )
        let pending = PeerConnection(connection: connection, noiseSession: session)
        pendingByObjectId[ObjectIdentifier(connection)] = pending
        recomputeConnectionState()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                NSLog("Gossip: inbound connection failed: \(error)")
                self?.teardownAny(pending)
            default:
                break
            }
        }
        connection.start(queue: queue)
        resolvePeerIPAddress(pending)
        startReceiveLoop(pending: pending)
        scheduleTimeout(for: pending)
    }

    /// Extracts the remote endpoint's bare IP address (stripping any zone
    /// ID like `%en0`) from an `NWConnection`'s current path, for both the
    /// initiator (dials an already-resolved `.hostPort`/IP endpoint) and
    /// responder (inbound connection; the remote endpoint is populated by
    /// the time the connection is ready/accepted) roles.
    private func resolvePeerIPAddress(_ pending: PeerConnection) {
        guard let remote = pending.connection.currentPath?.remoteEndpoint ?? pending.connection.endpoint as NWEndpoint? else { return }
        if case .hostPort(let host, _) = remote {
            let ipString = "\(host)"
            pending.peerHostWithZone = ipString
            pending.peerIPAddress = ipString.split(separator: "%").first.map(String.init) ?? ipString
        }
    }

    func ipAddress(for deviceId: String) -> String? {
        peers[deviceId]?.peerIPAddress
    }

    /// Like `ipAddress(for:)` but keeps an IPv6 `%zone` (e.g. `fe80::1%en0`), which a plain
    /// `NWConnection` to a link-local peer needs. Used to dial the screen bridge's WebSocket.
    func hostWithZone(for deviceId: String) -> String? {
        peers[deviceId]?.peerHostWithZone ?? peers[deviceId]?.peerIPAddress
    }

    /// Tears down the live connection to one specific peer, if any (e.g. after
    /// `trust.revoke`) — leaves every other peer untouched.
    func disconnect(deviceId: String) {
        if let peer = peers[deviceId] {
            teardown(peer: peer, deviceId: deviceId)
        }
    }

    // MARK: - Framing: [4-byte big-endian length][payload]

    private func sendFramed(_ payload: Data, over connection: NWConnection) {
        var lengthPrefix = UInt32(payload.count).bigEndian
        var framed = Data(bytes: &lengthPrefix, count: 4)
        framed.append(payload)
        connection.send(content: framed, completion: .contentProcessed { error in
            if let error {
                NSLog("Gossip: send failed: \(error)")
            }
        })
    }

    private func startReceiveLoop(pending: PeerConnection) {
        pending.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                pending.receiveBuffer.append(data)
                self.drainFrames(pending: pending)
            }
            if let error {
                NSLog("Gossip: receive error: \(error)")
                self.teardownAny(pending)
                return
            }
            if isComplete {
                self.teardownAny(pending)
                return
            }
            self.startReceiveLoop(pending: pending)
        }
    }

    private func drainFrames(pending: PeerConnection) {
        while pending.receiveBuffer.count >= 4 {
            let lengthBytes = pending.receiveBuffer.prefix(4)
            let length = lengthBytes.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
            let total = 4 + Int(length)
            guard pending.receiveBuffer.count >= total else { break }
            let framePayload = pending.receiveBuffer.subdata(in: 4..<total)
            pending.receiveBuffer.removeSubrange(0..<total)
            handleIncomingFrame(framePayload, pending: pending)
        }
    }

    private func handleIncomingFrame(_ payload: Data, pending: PeerConnection) {
        switch pending.noiseSession.state {
        case .uninitialized:
            // Responder path: this frame is handshake message 1.
            handleMessage1(payload, pending: pending)
        case .handshaking:
            // Initiator path: this frame is handshake message 2.
            handleMessage2(payload, pending: pending)
        case .established:
            handleTransportFrame(payload, pending: pending)
        case .failed:
            break
        }
    }

    private func handleMessage1(_ payload: Data, pending: PeerConnection) {
        do {
            let helloEnvelope = try Envelope.decode(payload)
            guard helloEnvelope.type == "handshake.hello" else {
                throw NoiseError.invalidMessage
            }
            guard let noiseBase64 = helloEnvelope.payload["noise"]?.stringValue,
                  let noiseBytes = Data(base64Encoded: noiseBase64) else {
                throw NoiseError.invalidMessage
            }
            _ = try pending.noiseSession.consumeMessage1(noiseBytes)

            let deviceName = helloEnvelope.payload["deviceName"]?.stringValue ?? "Android device"
            let deviceTypeRaw = helloEnvelope.payload["deviceType"]?.stringValue ?? DeviceType.androidPhone.rawValue
            let deviceType = DeviceType(rawValue: deviceTypeRaw) ?? .androidPhone
            let signingPublicKey = helloEnvelope.payload["signingPublicKey"]?.stringValue.flatMap { Data(base64Encoded: $0) } ?? Data()
            pending.pendingPeer = HandshakePeerInfo(deviceId: helloEnvelope.senderId, deviceName: deviceName, deviceType: deviceType, signingPublicKey: signingPublicKey)

            let message2 = try pending.noiseSession.createMessage2(payload: Data())
            let ackEnvelope = Envelope(
                type: "handshake.ack",
                senderId: identity.deviceId,
                recipientId: helloEnvelope.senderId,
                payload: .object([
                    "noise": .string(message2.base64EncodedString()),
                    "deviceName": .string(currentDeviceName()),
                    "deviceType": .string(DeviceType.mac.rawValue),
                    "signingPublicKey": .string(identity.signingKey.publicKey.rawRepresentation.base64EncodedString())
                ])
            )
            let framed = try ackEnvelope.encoded()
            sendFramed(framed, over: pending.connection)

            finalizeHandshake(pending: pending)
        } catch {
            NSLog("Gossip: handshake message 1 failed: \(error)")
            teardownAny(pending)
        }
    }

    private func handleMessage2(_ payload: Data, pending: PeerConnection) {
        do {
            let ackEnvelope = try Envelope.decode(payload)
            guard ackEnvelope.type == "handshake.ack" else {
                throw NoiseError.invalidMessage
            }
            guard let noiseBase64 = ackEnvelope.payload["noise"]?.stringValue,
                  let noiseBytes = Data(base64Encoded: noiseBase64) else {
                throw NoiseError.invalidMessage
            }
            _ = try pending.noiseSession.consumeMessage2(noiseBytes)

            let deviceName = ackEnvelope.payload["deviceName"]?.stringValue ?? "Android device"
            let deviceTypeRaw = ackEnvelope.payload["deviceType"]?.stringValue ?? DeviceType.androidPhone.rawValue
            let deviceType = DeviceType(rawValue: deviceTypeRaw) ?? .androidPhone
            let signingPublicKey = ackEnvelope.payload["signingPublicKey"]?.stringValue.flatMap { Data(base64Encoded: $0) } ?? Data()
            pending.pendingPeer = HandshakePeerInfo(deviceId: ackEnvelope.senderId, deviceName: deviceName, deviceType: deviceType, signingPublicKey: signingPublicKey)
            finalizeHandshake(pending: pending)
        } catch {
            NSLog("Gossip: handshake message 2 failed: \(error)")
            teardownAny(pending)
        }
    }

    private func finalizeHandshake(pending: PeerConnection) {
        guard let peer = pending.pendingPeer, let publicKey = pending.noiseSession.peerStaticKey else { return }

        if trustedDevices.isTrusted(deviceId: peer.deviceId) {
            promote(pending, peer: peer)
            trustedConnectedHandlers.forEach { $0(peer) }
            sendPresence(online: true)
            startHeartbeatMonitoring(for: pending)
            replayQueuedFrames(for: pending)
        } else if let onUntrustedHandshake {
            onUntrustedHandshake(peer, publicKey) { [weak self] confirmed in
                // The UI answers on the main thread; peers/Noise state live on `queue`.
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    if confirmed {
                        self.trustedDevices.addDevice(
                            deviceId: peer.deviceId,
                            publicKeyBase64: publicKey.rawRepresentation.base64EncodedString(),
                            deviceName: peer.deviceName,
                            deviceType: peer.deviceType,
                            signingPublicKeyBase64: peer.signingPublicKey.base64EncodedString()
                        )
                        self.promote(pending, peer: peer)
                        // Freshly-confirmed pairing reaches the same "connected" outcome
                        // as reconnecting to an already-trusted device — fire the same
                        // callbacks so PairingViewModel's state machine actually advances
                        // to `.paired` instead of being stuck at `.confirmingTrust`
                        // forever once the user taps Confirm.
                        self.trustedConnectedHandlers.forEach { $0(peer) }
                        self.newDevicePairedHandlers.forEach { $0(peer) }
                        self.sendPresence(online: true)
                        self.startHeartbeatMonitoring(for: pending)
                        self.replayQueuedFrames(for: pending)
                    } else {
                        self.teardownAny(pending)
                    }
                }
            }
        } else {
            // No pairing UI registered to confirm trust; refuse to proceed silently connected.
            teardownAny(pending)
        }
    }

    /// Moves a connection that just finished handshaking from `pendingByObjectId`
    /// into `peers`, keyed by the now-known `deviceId`. If a stale entry already
    /// exists for this `deviceId` (e.g. a previous connection that hasn't been
    /// cleaned up yet), it's torn down first.
    private func promote(_ pending: PeerConnection, peer: HandshakePeerInfo) {
        pendingByObjectId.removeValue(forKey: ObjectIdentifier(pending.connection))
        dialingDeviceIds.remove(peer.deviceId)
        if let stale = peers[peer.deviceId], stale !== pending {
            teardown(peer: stale, deviceId: peer.deviceId)
        }
        pending.deviceId = peer.deviceId
        peers[peer.deviceId] = pending
        recomputeConnectionState(preferring: peer.deviceId)
    }

    private func handleTransportFrame(_ payload: Data, pending: PeerConnection) {
        guard pending.deviceId != nil else {
            // Not promoted yet (awaiting trust confirmation): hold the frame, don't drop it.
            if !pending.queuedFrames.enqueue(payload) {
                NSLog("Gossip: too many frames before trust confirmation; closing")
                teardownAny(pending)
            }
            return
        }
        processTransportFrame(payload, pending: pending)
    }

    /// Decrypts and routes the frames queued during the confirmation window, in
    /// arrival order. Call on `queue` after `promote`.
    private func replayQueuedFrames(for pending: PeerConnection) {
        for frame in pending.queuedFrames.drain() {
            processTransportFrame(frame, pending: pending)
        }
    }

    private func processTransportFrame(_ payload: Data, pending: PeerConnection) {
        pending.lastReceivedAt = Date()
        guard let arrivedFrom = pending.deviceId else { return }
        do {
            let plaintext = try pending.noiseSession.decrypt(payload)
            // A raw (non-envelope) frame armed while handling the metadata envelope
            // that announced it (`hasRawFollowup: true`) — see `handleReceivedEnvelope`
            // and `docs/wire-protocol.md`'s "Large binary payloads" section. Must be
            // checked before attempting `Envelope.decode`, since a raw frame isn't JSON.
            if let rawHandler = pendingRawFrameHandlers.removeValue(forKey: arrivedFrom) {
                rawHandler(plaintext)
                return
            }
            let envelope = try Envelope.decode(plaintext)
            handleReceivedEnvelope(envelope, arrivedFrom: arrivedFrom)
        } catch {
            NSLog("Gossip: failed to decrypt/decode incoming envelope: \(error)")
        }
    }

    /// One-shot handlers for the raw binary frame expected to follow a metadata
    /// envelope from a specific peer, keyed by that peer's `deviceId`. Only ever
    /// touched from `handleTransportFrame`/`handleReceivedEnvelope`, both on `queue`.
    /// Every envelope with `hasRawFollowup: true` arms exactly one entry here — even
    /// a duplicate being dropped, or one neither addressed to us nor being forwarded —
    /// since the raw frame is physically coming next on this connection regardless,
    /// and must be consumed to keep the frame boundary in sync even when discarded.
    private var pendingRawFrameHandlers: [String: (Data) -> Void] = [:]

    /// The core mesh routing decision, run on every successfully decoded
    /// inbound envelope: deliver locally if it's addressed to us (directly or
    /// via broadcast), and/or forward it on toward wherever else it needs to
    /// go. See `docs/wire-protocol.md`'s "Multi-hop relay" section for the
    /// canonical algorithm both platforms implement.
    ///
    /// Forwarding is never a raw-ciphertext relay: each hop's Noise session is
    /// pairwise, so a frame decrypted under the sender's session here is
    /// re-encrypted from scratch under each forward target's own session by
    /// `send(envelope:to:)`.
    ///
    /// `hasRawFollowup` envelopes are handled differently: delivery and
    /// forwarding are both *deferred* until the raw frame that follows this
    /// envelope actually arrives (armed via `pendingRawFrameHandlers`), so that
    /// a relayed hop always forwards the metadata envelope and its raw frame
    /// atomically as a pair — never the metadata alone, which would desync a
    /// downstream hop's own "next frame is raw" expectation if some other
    /// message interleaved in between.
    private func handleReceivedEnvelope(_ envelope: Envelope, arrivedFrom: String) {
        // Any message from a device — even one relayed through another — proves it is reachable.
        if envelope.senderId != identity.deviceId {
            let sender = envelope.senderId
            DispatchQueue.main.async { [weak self] in self?.noteHeard(from: sender) }
        }
        guard recordSeen(envelope.id) else {
            // Already processed/forwarded this one — but if it carries a raw
            // follow-up, that frame is still physically coming next on this
            // connection and must be drained, just discarded rather than acted on.
            if envelope.hasRawFollowup {
                pendingRawFrameHandlers[arrivedFrom] = { _ in }
            }
            return
        }

        let isForMe = envelope.recipientId == identity.deviceId || envelope.broadcast
        let targets = envelope.ttl > 0 ? forwardTargets(for: envelope, arrivedFrom: arrivedFrom) : []

        if envelope.hasRawFollowup {
            pendingRawFrameHandlers[arrivedFrom] = { [weak self] data in
                guard let self else { return }
                if isForMe {
                    self.router.route(envelope)
                    DispatchQueue.main.async { [weak self] in
                        self?.onReceive?(envelope)
                        self?.onRawFrameReceived?(envelope, data)
                    }
                }
                guard !targets.isEmpty else { return }
                let forwarded = envelope.withTTL(envelope.ttl - 1)
                for target in targets {
                    try? self.send(forwarded, withRawFollowup: data, to: target)
                }
            }
            return
        }

        if isForMe {
            router.route(envelope)
            DispatchQueue.main.async { [weak self] in
                self?.onReceive?(envelope)
            }
        }
        guard !targets.isEmpty else { return }
        let forwarded = envelope.withTTL(envelope.ttl - 1)
        for target in targets {
            try? send(envelope: forwarded, to: target)
        }
    }

    /// Resolves which currently-connected peers an envelope should be sent/forwarded
    /// to. `arrivedFrom` is the peer this envelope was just relayed from (excluded from
    /// re-forwarding back to); pass `nil` for a locally-originated send.
    private func forwardTargets(for envelope: Envelope, arrivedFrom: String?) -> [PeerConnection] {
        if envelope.broadcast {
            return peers.compactMap { deviceId, peer in deviceId == arrivedFrom ? nil : peer }
        }
        guard let recipientId = envelope.recipientId, recipientId != identity.deviceId else {
            return []
        }
        if let direct = peers[recipientId] {
            return [direct]
        }
        // Not directly connected to the recipient — flood so it can find a
        // multi-hop path through whatever else we're connected to.
        return peers.compactMap { deviceId, peer in deviceId == arrivedFrom ? nil : peer }
    }

    /// Inserts `id` into the recently-seen cache. Returns `true` if this is the
    /// first time we've seen it (caller should process/deliver it), `false` if
    /// it's a duplicate (caller should drop it). Bounded to `dedupeCacheLimit`
    /// entries, oldest evicted first — generous relative to a small mesh's
    /// expected chat volume (clipboard/DND/media/roster-gossip), not a full
    /// time-windowed LRU since that precision isn't needed here.
    @discardableResult
    private func recordSeen(_ id: String) -> Bool {
        dedupeQueue.sync {
            if recentEnvelopeIdSet.contains(id) { return false }
            recentEnvelopeIdSet.insert(id)
            recentEnvelopeIds.append(id)
            if recentEnvelopeIds.count > Self.dedupeCacheLimit {
                let evicted = recentEnvelopeIds.removeFirst()
                recentEnvelopeIdSet.remove(evicted)
            }
            return true
        }
    }

    // MARK: - Sending application envelopes

    enum SendError: Error { case notConnected }

    /// Neither this nor per-peer sends gate on `connectionState` — only on the
    /// resolved peer's `noiseSession`/`connection` directly, which are the actual
    /// prerequisites for sending. `connectionState` is `@Published`, and Combine's
    /// documented (if easy to forget) behavior is that a `@Published` property's
    /// publisher fires *before* the underlying storage is actually updated — a
    /// subscriber reading `self.connectionState` synchronously from inside its own
    /// `.sink` (as `ConnectApp` does, to drive `DNDSyncManager.reportInitialSyncState()`
    /// on every fresh connect) can therefore see the *previous* value even though the
    /// value it was just handed says `.connected`. `peers`/`noiseSession` are plain
    /// stored properties set synchronously in the handshake-completion path itself,
    /// with no such lag, and are the real truth of "is there something to send on."
    ///
    /// Resolves targets from `envelope.broadcast`/`recipientId` exactly like the
    /// forwarding path (this *is* the forwarding path's entry point for a freshly
    /// originated, not-yet-relayed envelope — `arrivedFrom: nil`), and records the
    /// envelope's own `id` as seen so a self-addressed loop (e.g. a broadcast that
    /// somehow finds its way back around the mesh) is dropped rather than
    /// re-delivered to whoever just sent it.
    func send(envelope: Envelope) throws {
        guard featureSettings.isMessageAllowed(type: envelope.type) else { return }
        recordSeen(envelope.id)
        let targets = forwardTargets(for: envelope, arrivedFrom: nil)
        guard !targets.isEmpty else { throw SendError.notConnected }
        var lastError: Error?
        for target in targets {
            do {
                try send(envelope: envelope, to: target)
            } catch {
                lastError = error
            }
        }
        if let lastError {
            throw lastError
        }
    }

    private func send(envelope: Envelope, to peer: PeerConnection) throws {
        try peer.sendQueue.sync {
            let plaintext = try envelope.encoded()
            let ciphertext = try peer.noiseSession.encrypt(plaintext)
            sendFramed(ciphertext, over: peer.connection)
        }
    }

    /// Sends `envelope` to one directly-connected peer, immediately followed by a
    /// second raw (non-envelope) Noise-encrypted frame carrying `rawData` — the "large
    /// binary payload" convention in `docs/wire-protocol.md`. Both frames are written
    /// atomically under the peer's own send queue so nothing else (e.g. a concurrent
    /// DND update) can interleave a third frame between them, which would break that
    /// peer's "the very next frame is the raw payload" expectation — this holds at
    /// every hop, which is what makes relaying a raw-followup envelope safe (see
    /// `handleReceivedEnvelope`).
    private func send(_ envelope: Envelope, withRawFollowup rawData: Data, to peer: PeerConnection) throws {
        try peer.sendQueue.sync {
            let plaintext = try envelope.encoded()
            let ciphertext = try peer.noiseSession.encrypt(plaintext)
            sendFramed(ciphertext, over: peer.connection)
            let rawCiphertext = try peer.noiseSession.encrypt(rawData)
            sendFramed(rawCiphertext, over: peer.connection)
        }
    }

    /// Originates a `hasRawFollowup` envelope + its raw binary frame — the
    /// counterpart to `send(envelope:)` for a locally-originated (not relayed) send
    /// carrying a large binary payload (e.g. clipboard image sync). Resolves targets
    /// from `envelope.broadcast`/`recipientId` exactly like `send(envelope:)`; devices
    /// with no direct connection to any of those targets receive it via each target's
    /// own relay (see `handleReceivedEnvelope`), not directly from here.
    func send(_ envelope: Envelope, withRawFollowup rawData: Data) throws {
        guard featureSettings.isMessageAllowed(type: envelope.type) else { return }
        recordSeen(envelope.id)
        let targets = forwardTargets(for: envelope, arrivedFrom: nil)
        guard !targets.isEmpty else { throw SendError.notConnected }
        var lastError: Error?
        for target in targets {
            do {
                try send(envelope, withRawFollowup: rawData, to: target)
            } catch {
                lastError = error
            }
        }
        if let lastError {
            throw lastError
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

    /// Detects a *silently* dropped connection to one specific peer — the case
    /// `NWConnection`'s own path-viability tracking doesn't reliably cover.
    /// `NWConnection` reports `.failed` when the *local* network path becomes
    /// unusable (Wi-Fi off, etc.), but the peer vanishing without that — its
    /// Wi-Fi dropping, the OS killing/sleeping its process without a clean
    /// socket close, a NAT/carrier timeout on a cross-network path — can leave
    /// this side's connection sitting at "connected" indefinitely, with
    /// nothing to ever trigger the auto-reconnect loop for *that peer*. Sends
    /// a targeted `presence.heartbeat` to this peer periodically (proving
    /// outbound liveness) and checks `lastReceivedAt` (proving inbound
    /// liveness, from *any* received frame, not just heartbeat replies); if
    /// either fails, tears down only this peer's connection.
    private func startHeartbeatMonitoring(for peer: PeerConnection) {
        peer.heartbeatTimer?.invalidate()
        peer.lastReceivedAt = Date()
        let timer = Timer(timeInterval: Self.heartbeatInterval, repeats: true) { [weak self, weak peer] _ in
            guard let self, let peer else { return }
            self.checkHeartbeat(for: peer)
        }
        RunLoop.main.add(timer, forMode: .common)
        peer.heartbeatTimer = timer
    }

    private func checkHeartbeat(for peer: PeerConnection) {
        guard let deviceId = peer.deviceId, peers[deviceId] === peer else { return }
        let sendFailed: Bool
        do {
            let heartbeat = Envelope(type: "presence.heartbeat", senderId: identity.deviceId, recipientId: deviceId)
            try send(envelope: heartbeat, to: peer)
            sendFailed = false
        } catch {
            sendFailed = true
        }
        let stale = Date().timeIntervalSince(peer.lastReceivedAt) > Self.heartbeatTimeout
        guard sendFailed || stale else { return }
        NSLog("Gossip: heartbeat failed or peer \(deviceId) went stale (sendFailed=\(sendFailed), stale=\(stale)); closing connection")
        teardown(peer: peer, deviceId: deviceId)
    }

    private static let heartbeatInterval: TimeInterval = 20
    private static let heartbeatTimeout: TimeInterval = 3 * heartbeatInterval

    // MARK: - Teardown

    /// Tears down a promoted (`deviceId` known, tracked in `peers`) connection.
    private func teardown(peer: PeerConnection, deviceId: String) {
        peer.heartbeatTimer?.invalidate()
        peer.heartbeatTimer = nil
        peer.connection.cancel()
        if peers[deviceId] === peer {
            peers.removeValue(forKey: deviceId)
        }
        dialingDeviceIds.remove(deviceId)
        recomputeConnectionState()
    }

    /// Tears down a not-yet-promoted (still handshaking) connection.
    private func teardownPending(_ pending: PeerConnection) {
        pending.connection.cancel()
        pendingByObjectId.removeValue(forKey: ObjectIdentifier(pending.connection))
        if let target = pending.dialTargetDeviceId {
            dialingDeviceIds.remove(target)
        }
        recomputeConnectionState()
    }

    /// Tears down `pc` whichever state it's currently in — still pending, or
    /// already promoted into `peers` (in which case it's only removed if it's
    /// still the *current* entry for its `deviceId`, so a stale connection's
    /// delayed cleanup can never stomp a newer reconnect's live entry).
    private func teardownAny(_ pc: PeerConnection) {
        if let deviceId = pc.deviceId, peers[deviceId] === pc {
            teardown(peer: pc, deviceId: deviceId)
        } else {
            teardownPending(pc)
        }
    }

    private func recomputeConnectionState(preferring preferredDeviceId: String? = nil) {
        let ids = Set(peers.keys)
        let newState: ConnectionState
        if let preferredDeviceId, peers[preferredDeviceId] != nil {
            newState = .connected(deviceId: preferredDeviceId)
        } else if let any = ids.first {
            newState = .connected(deviceId: any)
        } else if !pendingByObjectId.isEmpty {
            newState = .handshaking
        } else if hasStarted {
            newState = .discovering
        } else {
            newState = .disconnected
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.connectedDeviceIds = ids
            self.connectionState = newState
            self.refreshMeshReachable()
        }
    }

    private func currentDeviceName() -> String {
        Host.current().localizedName ?? "Mac"
    }
}


/// Bounded FIFO of still-encrypted transport frames, see `PeerConnection.queuedFrames`.
struct PendingFrameQueue {
    static let limit = 256
    private var frames: [Data] = []

    /// Returns false (frame not stored) once the cap is hit.
    mutating func enqueue(_ frame: Data) -> Bool {
        guard frames.count < Self.limit else { return false }
        frames.append(frame)
        return true
    }

    mutating func drain() -> [Data] {
        defer { frames.removeAll() }
        return frames
    }
}
