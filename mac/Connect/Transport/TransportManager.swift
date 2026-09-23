import Foundation
import Network
import CryptoKit
import Combine

/// Everything needed to identify + greet a peer during the Noise_IK handshake.
struct HandshakePeerInfo {
    let deviceId: String
    let deviceName: String
    let deviceType: DeviceType
}

/// Owns the connection lifecycle to exactly one peer device at a time (v1 is a
/// single Mac <-> single phone relationship at the transport layer, even
/// though `TrustedDevicesStore` is schema-ready for more). Drives
/// `LocalDiscovery` to find/advertise, opens a raw `NWConnection`, performs
/// the Noise_IK handshake via `NoiseSession`, and once connected frames /
/// deframes `Envelope`s per the wire protocol.
final class TransportManager: ObservableObject {
    enum ConnectionState: Equatable {
        case disconnected
        case discovering
        case handshaking
        case connected(deviceId: String)
    }

    @Published private(set) var connectionState: ConnectionState = .disconnected

    /// Fired for every successfully decoded, post-handshake envelope.
    var onReceive: ((Envelope) -> Void)?

    /// Fired when a Noise handshake completes with a peer that is not yet in
    /// `TrustedDevicesStore`. `PairingViewModel` uses this to prompt the user
    /// to confirm + trust the new device. Returning `true` from the completion
    /// keeps the connection open; `false` tears it down.
    var onUntrustedHandshake: ((_ peer: HandshakePeerInfo, _ publicKey: Curve25519.KeyAgreement.PublicKey, _ confirm: @escaping (Bool) -> Void) -> Void)?

    /// Fired when a handshake completes with an already-trusted peer, i.e. a
    /// normal reconnect.
    var onTrustedConnected: ((HandshakePeerInfo) -> Void)?

    let router = MessageRouter()

    private let discovery = LocalDiscovery()
    private let identity = IdentityKeyStore.shared
    private let trustedDevices: TrustedDevicesStore

    /// The remote endpoint's IP address (no port) for the current connection,
    /// once resolved. Used by `ADBWirelessPairing`'s defense-in-depth check
    /// to confirm the ADB-paired device is the same phone already
    /// trust-paired over Connect's Noise-encrypted transport.
    private(set) var connectedPeerIPAddress: String?

    private var connection: NWConnection?
    private var noiseSession: NoiseSession?
    private var pendingPeer: HandshakePeerInfo?
    private var receiveBuffer = Data()
    private let queue = DispatchQueue(label: "com.connect.app.transportmanager")

    /// Set when we're actively trying to dial a specific discovered peer (as
    /// the initiator, we need to know which trusted static key to expect).
    private var expectedRemoteStaticKey: Curve25519.KeyAgreement.PublicKey?

    /// Updated on every successfully-decrypted frame (any type, not just heartbeats) in
    /// `handleTransportFrame` — see `startHeartbeatMonitoring`'s doc for why this exists.
    private var lastReceivedAt: Date = .distantPast
    private var heartbeatTimer: Timer?

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

    /// Starts advertising this Mac on the local network and browsing for
    /// peers. Automatically dials any discovered peer that is already trusted.
    /// Safe to call repeatedly — only the first call has any effect.
    func start(deviceName: String = Host.current().localizedName ?? "Mac") {
        guard !hasStarted else { return }
        hasStarted = true
        setState(.discovering)

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
            NSLog("Connect: failed to advertise on fixed port \(Self.defaultPort), falling back to an ephemeral port: \(error)")
            do {
                try discovery.startAdvertising(
                    deviceId: identity.deviceId,
                    deviceName: deviceName,
                    publicKeyFingerprint: identity.publicKeyFingerprint
                )
            } catch {
                NSLog("Connect: failed to start advertising: \(error)")
            }
        }
        discovery.startBrowsing()
    }

    func stop() {
        hasStarted = false
        discovery.stopAdvertising()
        discovery.stopBrowsing()
        teardownConnection()
        setState(.disconnected)
    }

    private func handleDiscoveredPeers(_ peers: [DiscoveredPeer]) {
        guard connection == nil else { return } // already connecting/connected
        guard let trustedPeer = peers.first(where: { trustedDevices.isTrusted(deviceId: $0.deviceId) }) else { return }
        guard let trusted = trustedDevices.device(for: trustedPeer.deviceId),
              let keyData = Data(base64Encoded: trusted.publicKeyBase64),
              let staticKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyData) else { return }
        connect(to: trustedPeer, remoteStaticKey: staticKey)
    }

    // MARK: - Outbound connection (initiator role)

    /// Dials a discovered peer as the Noise_IK initiator. `remoteStaticKey`
    /// must be known ahead of time: either from `TrustedDevicesStore` (a
    /// reconnect) or from a freshly-scanned pairing QR code (first connect).
    func connect(to peer: DiscoveredPeer, remoteStaticKey: Curve25519.KeyAgreement.PublicKey) {
        dial(endpoint: peer.endpoint, remoteStaticKey: remoteStaticKey)
    }

    /// Dials a manually-configured fallback address (e.g. a Tailscale IP) directly,
    /// bypassing Bonjour discovery entirely — the Mac-side counterpart to Android's
    /// `SyncForegroundService.runFallbackDialLoop`. Both sides normally rely on
    /// LAN-only discovery (Mac browses, Android just listens); this is what makes
    /// reconnecting possible at all once the two devices aren't on the same LAN/mDNS
    /// domain. See `TrustedDevice.fallbackHost` and `docs/wire-protocol.md`.
    func connect(toFallbackHost host: String, remoteStaticKey: Curve25519.KeyAgreement.PublicKey) {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: Self.defaultPort)
        dial(endpoint: endpoint, remoteStaticKey: remoteStaticKey)
    }

    private func dial(endpoint: NWEndpoint, remoteStaticKey: Curve25519.KeyAgreement.PublicKey) {
        teardownConnection()
        setState(.handshaking)

        expectedRemoteStaticKey = remoteStaticKey
        let session = NoiseSession(
            role: .initiator,
            localStaticKey: identity.agreementKey,
            remoteStaticKey: remoteStaticKey
        )
        noiseSession = session

        let nwConnection = NWConnection(to: endpoint, using: .tcp)
        connection = nwConnection
        nwConnection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState(state, connection: nwConnection)
        }
        nwConnection.start(queue: queue)
    }

    private func handleConnectionState(_ state: NWConnection.State, connection: NWConnection) {
        switch state {
        case .ready:
            resolvePeerIPAddress(connection)
            sendHandshakeMessage1(over: connection)
            startReceiveLoop(on: connection)
        case .failed(let error):
            NSLog("Connect: connection failed: \(error)")
            teardownConnection()
            setState(.discovering)
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
    private func sendHandshakeMessage1(over connection: NWConnection) {
        guard let session = noiseSession else { return }
        guard let message = try? session.createMessage1(payload: Data()) else { return }
        let envelope = Envelope(
            type: "handshake.hello",
            senderId: identity.deviceId,
            payload: .object([
                "noise": .string(message.base64EncodedString()),
                "deviceName": .string(currentDeviceName()),
                "deviceType": .string(DeviceType.mac.rawValue)
            ])
        )
        guard let framed = try? envelope.encoded() else { return }
        sendFramed(framed, over: connection)
    }

    // MARK: - Inbound connection (responder role)

    private func accept(connection: NWConnection) {
        teardownConnection()
        setState(.handshaking)

        // Responder doesn't know the initiator's static key yet; it's
        // learned from message 1.
        let session = NoiseSession(
            role: .responder,
            localStaticKey: identity.agreementKey,
            remoteStaticKey: nil
        )
        noiseSession = session

        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                NSLog("Connect: inbound connection failed: \(error)")
                self?.teardownConnection()
                self?.setState(.discovering)
            default:
                break
            }
        }
        connection.start(queue: queue)
        resolvePeerIPAddress(connection)
        startReceiveLoop(on: connection)
    }

    /// Extracts the remote endpoint's bare IP address (stripping any zone
    /// ID like `%en0`) from an `NWConnection`'s current path, for both the
    /// initiator (dials an already-resolved `.hostPort`/IP endpoint) and
    /// responder (inbound connection; the remote endpoint is populated by
    /// the time the connection is ready/accepted) roles.
    private func resolvePeerIPAddress(_ connection: NWConnection) {
        guard let remote = connection.currentPath?.remoteEndpoint ?? connection.endpoint as NWEndpoint? else { return }
        if case .hostPort(let host, _) = remote {
            let ipString = "\(host)"
            connectedPeerIPAddress = ipString.split(separator: "%").first.map(String.init) ?? ipString
        }
    }

    // MARK: - Framing: [4-byte big-endian length][payload]

    private func sendFramed(_ payload: Data, over connection: NWConnection) {
        var lengthPrefix = UInt32(payload.count).bigEndian
        var framed = Data(bytes: &lengthPrefix, count: 4)
        framed.append(payload)
        connection.send(content: framed, completion: .contentProcessed { error in
            if let error {
                NSLog("Connect: send failed: \(error)")
            }
        })
    }

    private func startReceiveLoop(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.drainFrames(from: connection)
            }
            if let error {
                NSLog("Connect: receive error: \(error)")
                self.teardownConnection()
                self.setState(.discovering)
                return
            }
            if isComplete {
                self.teardownConnection()
                self.setState(.discovering)
                return
            }
            self.startReceiveLoop(on: connection)
        }
    }

    private func drainFrames(from connection: NWConnection) {
        while receiveBuffer.count >= 4 {
            let lengthBytes = receiveBuffer.prefix(4)
            let length = lengthBytes.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
            let total = 4 + Int(length)
            guard receiveBuffer.count >= total else { break }
            let framePayload = receiveBuffer.subdata(in: 4..<total)
            receiveBuffer.removeSubrange(0..<total)
            handleIncomingFrame(framePayload, connection: connection)
        }
    }

    private func handleIncomingFrame(_ payload: Data, connection: NWConnection) {
        guard let session = noiseSession else { return }

        switch session.state {
        case .uninitialized:
            // Responder path: this frame is handshake message 1.
            handleMessage1(payload, session: session, connection: connection)
        case .handshaking:
            // Initiator path: this frame is handshake message 2.
            handleMessage2(payload, session: session, connection: connection)
        case .established:
            handleTransportFrame(payload, session: session)
        case .failed:
            break
        }
    }

    private func handleMessage1(_ payload: Data, session: NoiseSession, connection: NWConnection) {
        do {
            let helloEnvelope = try Envelope.decode(payload)
            guard helloEnvelope.type == "handshake.hello" else {
                throw NoiseError.invalidMessage
            }
            guard let noiseBase64 = helloEnvelope.payload["noise"]?.stringValue,
                  let noiseBytes = Data(base64Encoded: noiseBase64) else {
                throw NoiseError.invalidMessage
            }
            _ = try session.consumeMessage1(noiseBytes)

            let deviceName = helloEnvelope.payload["deviceName"]?.stringValue ?? "Android device"
            let deviceTypeRaw = helloEnvelope.payload["deviceType"]?.stringValue ?? DeviceType.androidPhone.rawValue
            let deviceType = DeviceType(rawValue: deviceTypeRaw) ?? .androidPhone
            pendingPeer = HandshakePeerInfo(deviceId: helloEnvelope.senderId, deviceName: deviceName, deviceType: deviceType)

            let message2 = try session.createMessage2(payload: Data())
            let ackEnvelope = Envelope(
                type: "handshake.ack",
                senderId: identity.deviceId,
                recipientId: helloEnvelope.senderId,
                payload: .object([
                    "noise": .string(message2.base64EncodedString()),
                    "deviceName": .string(currentDeviceName()),
                    "deviceType": .string(DeviceType.mac.rawValue)
                ])
            )
            let framed = try ackEnvelope.encoded()
            sendFramed(framed, over: connection)

            finalizeHandshake(session: session)
        } catch {
            NSLog("Connect: handshake message 1 failed: \(error)")
            teardownConnection()
            setState(.discovering)
        }
    }

    private func handleMessage2(_ payload: Data, session: NoiseSession, connection: NWConnection) {
        do {
            let ackEnvelope = try Envelope.decode(payload)
            guard ackEnvelope.type == "handshake.ack" else {
                throw NoiseError.invalidMessage
            }
            guard let noiseBase64 = ackEnvelope.payload["noise"]?.stringValue,
                  let noiseBytes = Data(base64Encoded: noiseBase64) else {
                throw NoiseError.invalidMessage
            }
            _ = try session.consumeMessage2(noiseBytes)

            let deviceName = ackEnvelope.payload["deviceName"]?.stringValue ?? "Android device"
            let deviceTypeRaw = ackEnvelope.payload["deviceType"]?.stringValue ?? DeviceType.androidPhone.rawValue
            let deviceType = DeviceType(rawValue: deviceTypeRaw) ?? .androidPhone
            pendingPeer = HandshakePeerInfo(deviceId: ackEnvelope.senderId, deviceName: deviceName, deviceType: deviceType)
            finalizeHandshake(session: session)
        } catch {
            NSLog("Connect: handshake message 2 failed: \(error)")
            teardownConnection()
            setState(.discovering)
        }
    }

    private func finalizeHandshake(session: NoiseSession) {
        guard let peer = pendingPeer, let publicKey = session.peerStaticKey else { return }

        if trustedDevices.isTrusted(deviceId: peer.deviceId) {
            setState(.connected(deviceId: peer.deviceId))
            onTrustedConnected?(peer)
            sendPresence(online: true)
            startHeartbeatMonitoring()
        } else if let onUntrustedHandshake {
            onUntrustedHandshake(peer, publicKey) { [weak self] confirmed in
                guard let self else { return }
                if confirmed {
                    self.trustedDevices.addDevice(
                        deviceId: peer.deviceId,
                        publicKeyBase64: publicKey.rawRepresentation.base64EncodedString(),
                        deviceName: peer.deviceName,
                        deviceType: peer.deviceType
                    )
                    self.setState(.connected(deviceId: peer.deviceId))
                    // Freshly-confirmed pairing reaches the same "connected" outcome
                    // as reconnecting to an already-trusted device — fire the same
                    // callback so PairingViewModel's state machine actually advances
                    // to `.paired` instead of being stuck at `.confirmingTrust`
                    // forever once the user taps Confirm.
                    self.onTrustedConnected?(peer)
                    self.sendPresence(online: true)
                    self.startHeartbeatMonitoring()
                } else {
                    self.teardownConnection()
                    self.setState(.discovering)
                }
            }
        } else {
            // No pairing UI registered to confirm trust; refuse to proceed silently connected.
            teardownConnection()
            setState(.discovering)
        }
    }

    private func handleTransportFrame(_ payload: Data, session: NoiseSession) {
        lastReceivedAt = Date()
        do {
            let plaintext = try session.decrypt(payload)
            let envelope = try Envelope.decode(plaintext)

            // Routed synchronously, still on the transport's internal receive
            // queue (per `MessageRouter`'s contract: handlers hop to the main
            // thread themselves if they need to).
            router.route(envelope)
            DispatchQueue.main.async { [weak self] in
                self?.onReceive?(envelope)
            }
        } catch {
            NSLog("Connect: failed to decrypt/decode incoming envelope: \(error)")
        }
    }

    // MARK: - Sending application envelopes

    enum SendError: Error { case notConnected }

    /// Serializes every `session.encrypt(...)` + `sendFramed(...)` pair.
    /// `NoiseCipherState`'s nonce counter is mutable, unsynchronized state —
    /// `ClipboardSyncManager`'s poll timer, `NotificationMirrorManager`,
    /// `MediaControlManager`, and `DNDSyncManager` can all call `send`/`sendRawFrame`
    /// concurrently from different threads.
    /// Without serialization, two concurrent encrypts can race on the same
    /// nonce (or a `sendFramed` write can land on the wire out of order
    /// relative to the nonce it was encrypted with) — the receiver's AEAD
    /// nonce only advances on a *successful* decrypt, so one corrupted frame
    /// permanently desyncs the cipher and every message after it fails to
    /// decrypt for the rest of the connection. This must be a queue distinct
    /// from `queue` (the connection's own receive-callback queue): handshake
    /// completion (`finalizeHandshake` -> `sendPresence` -> `send`) runs
    /// synchronously from a `queue`-context receive callback, so serializing
    /// through `queue` itself here would deadlock.
    private let sendQueue = DispatchQueue(label: "com.connect.app.transportmanager.send")

    /// Neither this nor `sendRawFrame` gate on `connectionState` — only on `noiseSession`/
    /// `connection` directly, which are the actual prerequisites for sending. `connectionState`
    /// is `@Published`, and Combine's documented (if easy to forget) behavior is that a
    /// `@Published` property's publisher fires *before* the underlying storage is actually
    /// updated — a subscriber reading `self.connectionState` synchronously from inside its own
    /// `.sink` (as `ConnectApp` does, to drive `DNDSyncManager.reportInitialSyncState()` on
    /// every fresh connect) can therefore see the *previous* value even though the value it
    /// was just handed says `.connected`. That raced this exact call, throwing `notConnected`
    /// on literally the first send after every connection. `noiseSession`/`connection` are
    /// plain stored properties set synchronously in the handshake-completion path itself, with
    /// no such lag, and are the real truth of "is there something to send on."
    func send(envelope: Envelope) throws {
        try sendQueue.sync {
            guard let session = noiseSession, let connection else {
                throw SendError.notConnected
            }
            let plaintext = try envelope.encoded()
            let ciphertext = try session.encrypt(plaintext)
            sendFramed(ciphertext, over: connection)
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

    func sendHeartbeat() throws {
        let envelope = Envelope(type: "presence.heartbeat", senderId: identity.deviceId, broadcast: true)
        try send(envelope: envelope)
    }

    /// Detects a *silently* dropped connection — the case `NWConnection`'s own
    /// path-viability tracking doesn't reliably cover. `NWConnection` reports `.failed`
    /// when the *local* network path becomes unusable (Wi-Fi off, etc.), but the peer
    /// vanishing without that — its Wi-Fi dropping, the OS killing/sleeping its process
    /// without a clean socket close, a NAT/carrier timeout on a cross-network path — can
    /// leave this side's connection sitting at `.connected` indefinitely, with nothing to
    /// ever trigger the auto-reconnect loop. Sends `presence.heartbeat` periodically
    /// (proving outbound liveness) and checks `lastReceivedAt` (proving inbound liveness,
    /// from *any* received frame, not just heartbeat replies); if either fails, tears the
    /// connection down and returns to `.discovering` so it can actually recover.
    private func startHeartbeatMonitoring() {
        heartbeatTimer?.invalidate()
        lastReceivedAt = Date()
        let timer = Timer(timeInterval: Self.heartbeatInterval, repeats: true) { [weak self] _ in
            self?.checkHeartbeat()
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    private func checkHeartbeat() {
        let sendFailed: Bool
        do {
            try sendHeartbeat()
            sendFailed = false
        } catch {
            sendFailed = true
        }
        let stale = Date().timeIntervalSince(lastReceivedAt) > Self.heartbeatTimeout
        guard sendFailed || stale else { return }
        NSLog("Connect: heartbeat failed or peer went stale (sendFailed=\(sendFailed), stale=\(stale)); closing connection")
        teardownConnection()
        setState(.discovering)
    }

    private static let heartbeatInterval: TimeInterval = 20
    private static let heartbeatTimeout: TimeInterval = 3 * heartbeatInterval

    // MARK: - Teardown

    private func teardownConnection() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        connection?.cancel()
        connection = nil
        noiseSession = nil
        pendingPeer = nil
        receiveBuffer.removeAll()
        connectedPeerIPAddress = nil
    }

    private func setState(_ state: ConnectionState) {
        DispatchQueue.main.async { [weak self] in
            self?.connectionState = state
        }
    }

    private func currentDeviceName() -> String {
        Host.current().localizedName ?? "Mac"
    }
}

