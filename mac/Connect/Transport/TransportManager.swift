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

    private var connection: NWConnection?
    private var noiseSession: NoiseSession?
    private var pendingPeer: HandshakePeerInfo?
    private var receiveBuffer = Data()
    private let queue = DispatchQueue(label: "com.connect.app.transportmanager")

    /// Set when we're actively trying to dial a specific discovered peer (as
    /// the initiator, we need to know which trusted static key to expect).
    private var expectedRemoteStaticKey: Curve25519.KeyAgreement.PublicKey?

    init(trustedDevices: TrustedDevicesStore = .shared) {
        self.trustedDevices = trustedDevices
    }

    // MARK: - Lifecycle

    /// Starts advertising this Mac on the local network and browsing for
    /// peers. Automatically dials any discovered peer that is already trusted.
    func start(deviceName: String = Host.current().localizedName ?? "Mac") {
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
                publicKeyFingerprint: identity.publicKeyFingerprint
            )
        } catch {
            NSLog("Connect: failed to start advertising: \(error)")
        }
        discovery.startBrowsing()
    }

    func stop() {
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
        teardownConnection()
        setState(.handshaking)

        expectedRemoteStaticKey = remoteStaticKey
        let session = NoiseSession(
            role: .initiator,
            localStaticKey: identity.agreementKey,
            remoteStaticKey: remoteStaticKey
        )
        noiseSession = session

        let nwConnection = NWConnection(to: peer.endpoint, using: .tcp)
        connection = nwConnection
        nwConnection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState(state, connection: nwConnection)
        }
        nwConnection.start(queue: queue)
    }

    private func handleConnectionState(_ state: NWConnection.State, connection: NWConnection) {
        switch state {
        case .ready:
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

    private func sendHandshakeMessage1(over connection: NWConnection) {
        guard let session = noiseSession else { return }
        let hello = HandshakeHelloPayload(deviceId: identity.deviceId, deviceName: currentDeviceName(), deviceType: .mac)
        guard let payloadData = try? JSONEncoder().encode(hello) else { return }
        guard let message = try? session.createMessage1(payload: payloadData) else { return }
        sendFramed(message, over: connection)
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
        startReceiveLoop(on: connection)
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
            let helloData = try session.consumeMessage1(payload)
            let hello = try JSONDecoder().decode(HandshakeHelloPayload.self, from: helloData)
            pendingPeer = HandshakePeerInfo(deviceId: hello.deviceId, deviceName: hello.deviceName, deviceType: hello.deviceType)

            let ack = HandshakeAckPayload(deviceId: identity.deviceId, deviceName: currentDeviceName(), deviceType: .mac)
            let ackData = try JSONEncoder().encode(ack)
            let message2 = try session.createMessage2(payload: ackData)
            sendFramed(message2, over: connection)

            finalizeHandshake(session: session)
        } catch {
            NSLog("Connect: handshake message 1 failed: \(error)")
            teardownConnection()
            setState(.discovering)
        }
    }

    private func handleMessage2(_ payload: Data, session: NoiseSession, connection: NWConnection) {
        do {
            let ackData = try session.consumeMessage2(payload)
            let ack = try JSONDecoder().decode(HandshakeAckPayload.self, from: ackData)
            pendingPeer = HandshakePeerInfo(deviceId: ack.deviceId, deviceName: ack.deviceName, deviceType: ack.deviceType)
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
                    self.sendPresence(online: true)
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
        do {
            let plaintext = try session.decrypt(payload)
            let envelope = try Envelope.decode(plaintext)
            DispatchQueue.main.async { [weak self] in
                self?.router.route(envelope)
                self?.onReceive?(envelope)
            }
        } catch {
            NSLog("Connect: failed to decrypt/decode incoming envelope: \(error)")
        }
    }

    // MARK: - Sending application envelopes

    enum SendError: Error { case notConnected }

    func send(envelope: Envelope) throws {
        guard case .connected = connectionState, let session = noiseSession, let connection else {
            throw SendError.notConnected
        }
        let plaintext = try envelope.encoded()
        let ciphertext = try session.encrypt(plaintext)
        sendFramed(ciphertext, over: connection)
    }

    func sendPresence(online: Bool) {
        guard case .connected = connectionState else { return }
        let envelope = Envelope(
            type: online ? "presence.online" : "presence.offline",
            senderId: identity.deviceId,
            broadcast: true
        )
        try? send(envelope: envelope)
    }

    func sendHeartbeat() {
        guard case .connected = connectionState else { return }
        let envelope = Envelope(type: "presence.heartbeat", senderId: identity.deviceId, broadcast: true)
        try? send(envelope: envelope)
    }

    // MARK: - Teardown

    private func teardownConnection() {
        connection?.cancel()
        connection = nil
        noiseSession = nil
        pendingPeer = nil
        receiveBuffer.removeAll()
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

// MARK: - Handshake payload shapes

/// The `handshake.hello` payload, carried as the encrypted payload of Noise
/// message 1 (initiator -> responder).
struct HandshakeHelloPayload: Codable {
    let deviceId: String
    let deviceName: String
    let deviceType: DeviceType
}

/// The `handshake.ack` payload, carried as the encrypted payload of Noise
/// message 2 (responder -> initiator).
struct HandshakeAckPayload: Codable {
    let deviceId: String
    let deviceName: String
    let deviceType: DeviceType
}
