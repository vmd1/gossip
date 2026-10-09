import Foundation
import CryptoKit
import GossipCoreKit

/// The only file that talks to the Rust engine (`desktop/core`, through the UniFFI package `GossipCoreKit`).
///
/// The engine owns the protocol: Noise_IK, framing, envelope signing and verification, the mesh forwarding rules, trust
/// gating of new devices, heartbeats and reconciliation timing. It is sans-IO: this file feeds it bytes and events and
/// turns what it returns into `BridgeAction`s that `TransportManager` carries out on real sockets. Everything FFI
/// shaped (generated types, JSON payloads, the trust snapshot format) stays here, so the rest of the app keeps using
/// its own `Envelope`, `HandshakePeerInfo` and `TrustedDevicesStore`.
///
/// Not thread-safe by itself on purpose: `TransportManager` calls it only from its serial queue, which is also what
/// keeps the bytes written to a socket in the order the engine produced them (Noise nonces are implicit counters).
final class CoreBridge {
    /// What `TransportManager` must do (or tell the rest of the app) as a result of one engine call.
    enum BridgeAction {
        /// Write these bytes (already length-framed) to the connection.
        case send(conn: UInt64, bytes: Data)
        /// Close the connection. The engine has already forgotten it.
        case close(conn: UInt64)
        case peerConnected(conn: UInt64, peer: HandshakePeerInfo, newlyPaired: Bool)
        case peerDisconnected(deviceId: String)
        /// An unknown device needs the user's confirmation; answer with `confirmPairing`.
        case pairingPrompt(conn: UInt64, peer: HandshakePeerInfo, publicKey: Curve25519.KeyAgreement.PublicKey)
        case pairingPromptCancelled(conn: UInt64)
        case deliver(Envelope, raw: Data?)
        /// A validated message from this device arrived (even relayed): it is reachable.
        case heard(deviceId: String)
        /// The trust roster changed; the JSON is the engine's snapshot.
        case trustChanged(snapshotJSON: String)
        case deviceRevoked(deviceId: String)
        /// A reconciliation resend is due: `peer` for the on-connect send to one peer, `nil` for the periodic broadcast.
        case reconcileDue(task: String, peer: String?)
        /// Open a WebSocket to the relay at `url`, then call `relaySocketOpened` (or `relaySocketClosed` if it fails).
        case relayConnect(url: String)
        case relaySendText(String)
        case relaySendBinary(Data)
        /// Close the relay socket. The engine already considers it gone: do not report its close back.
        case relayClose
        case relayJoined(members: UInt32)
        case relayDown
        /// A hint for the UI (`upgrade_required`, `denied`, `disabled`, `join_failed`, ...); the engine backs off itself.
        case relayError(code: String)
        /// The mesh topic changed. The secret must be persisted in secure storage and never logged or interpolated
        /// into a message (`TransportManager` only hands it to `RelayTopicStore`).
        case topicChanged(secret: Data, epoch: UInt64)
    }

    enum BridgeError: Error, Equatable {
        case notConnected
        case tooLarge
        case invalid(String)
    }

    private let core: GossipCoreKit.GossipCore

    /// Connection ids at or above this are the engine's virtual ids for peers reached through the relay.
    static let virtualConnBase: UInt64 = 1 << 63

    /// - Parameter disabledFeatures: raw values of the features turned off on this device (`FeatureSettings`).
    init(identity: IdentityKeyStore, deviceName: String, trustedDevices: TrustedDevicesStore, disabledFeatures: [String]) throws {
        core = try GossipCoreKit.GossipCore(
            deviceId: identity.deviceId,
            deviceName: deviceName,
            deviceType: DeviceType.mac.rawValue,
            noiseSecret: identity.agreementKey.rawRepresentation,
            signingSeed: identity.signingKey.rawRepresentation,
            trustJson: trustedDevices.exportCoreSnapshot(),
            disabledFeatures: disabledFeatures,
            clock: nil
        )
    }

    // MARK: - Connections

    func accepted(conn: UInt64) throws -> [BridgeAction] {
        try map { try core.connectionAccepted(conn: conn) }
    }

    func dial(conn: UInt64, target: String, remoteStaticKey: Data, pairingToken: String? = nil) throws -> [BridgeAction] {
        try map { try core.dial(conn: conn, target: target, remoteStatic: remoteStaticKey, pairingToken: pairingToken) }
    }

    func bytesReceived(conn: UInt64, _ bytes: Data) -> [BridgeAction] {
        convert(core.bytesReceived(conn: conn, bytes: bytes))
    }

    func connectionClosed(conn: UInt64) -> [BridgeAction] {
        convert(core.connectionClosed(conn: conn))
    }

    func disconnect(deviceId: String) -> [BridgeAction] {
        convert(core.disconnect(deviceId: deviceId))
    }

    func tick() -> [BridgeAction] {
        convert(core.tick())
    }

    func shouldDial(deviceId: String) -> Bool { core.shouldDial(deviceId: deviceId) }

    // MARK: - Relay

    /// Turns the relay on or off. `origin` is `wss://host` (exactly what the relay is configured with: it is signed into
    /// every join). Returns `relayConnect` when enabling with a topic.
    func relayConfigure(enabled: Bool, origin: String) -> [BridgeAction] {
        convert(core.relayConfigure(enabled: enabled, origin: origin))
    }
    func relaySocketOpened() -> [BridgeAction] { convert(core.relaySocketOpened()) }
    func relaySocketClosed() -> [BridgeAction] { convert(core.relaySocketClosed()) }
    func relayTextReceived(_ text: String) -> [BridgeAction] { convert(core.relayTextReceived(text: text)) }
    func relayBinaryReceived(_ bytes: Data) -> [BridgeAction] { convert(core.relayBinaryReceived(bytes: bytes)) }
    /// "disabled", "no_topic", "disconnected", "connecting" or "joined".
    func relayStatus() -> String { core.relayStatus() }
    func isRelayed(deviceId: String) -> Bool { core.isRelayed(deviceId: deviceId) }
    func setLanGraceMs(_ ms: Int64) { core.setLanGraceMs(ms: ms) }
    /// Loads the persisted mesh topic at startup, before the first `tick`.
    func setTopic(secret: Data, epoch: UInt64) throws -> [BridgeAction] {
        try map { try core.setTopic(secret: secret, epoch: epoch) }
    }
    func isConnected(deviceId: String) -> Bool { core.isConnected(deviceId: deviceId) }
    func connectedPeers() -> [String] { core.connectedPeers() }

    // MARK: - Pairing and trust

    func armPairing(token: String) { core.armPairing(token: token) }
    func disarmPairing() { core.disarmPairing() }

    func confirmPairing(conn: UInt64, accepted: Bool) -> [BridgeAction] {
        convert(core.confirmPairing(conn: conn, accepted: accepted))
    }

    /// Revokes a device: removes its trust, drops its connection and broadcasts `trust.revoke`.
    func revokeDevice(deviceId: String) -> [BridgeAction] {
        convert(core.revokeDevice(deviceId: deviceId))
    }

    /// The `trust.roster_update` for the current roster, targeted at `peer` or broadcast; send it with `send`.
    func rosterUpdate(peer: String?) -> Envelope {
        Self.appEnvelope(core.rosterUpdate(peer: peer))
    }

    func setDisabledFeatures(_ keys: [String]) {
        try? core.setDisabledFeatures(keys: keys)
    }

    // MARK: - Sending

    func send(_ envelope: Envelope) throws -> [BridgeAction] {
        try map { try core.send(envelope: try Self.coreEnvelope(envelope)) }
    }

    func send(_ envelope: Envelope, raw: Data) throws -> [BridgeAction] {
        try map { try core.sendWithRaw(envelope: try Self.coreEnvelope(envelope), raw: raw) }
    }

    // MARK: - Conversion

    private func map(_ body: () throws -> [GossipCoreKit.Action]) throws -> [BridgeAction] {
        do {
            return convert(try body())
        } catch let error as GossipCoreKit.GossipError {
            switch error {
            case .NotConnected: throw BridgeError.notConnected
            case .TooLarge: throw BridgeError.tooLarge
            case .InvalidArgument(let reason), .Unsignable(let reason), .Dial(let reason): throw BridgeError.invalid(reason)
            case .Encryption: throw BridgeError.invalid("encryption failed")
            }
        }
    }

    private func convert(_ actions: [GossipCoreKit.Action]) -> [BridgeAction] {
        actions.compactMap { action in
            switch action {
            case .send(let conn, let bytes): return .send(conn: conn, bytes: bytes)
            case .close(let conn): return .close(conn: conn)
            case .peerConnected(let conn, let peer, let newlyPaired):
                return .peerConnected(conn: conn, peer: Self.peerInfo(peer), newlyPaired: newlyPaired)
            case .peerDisconnected(let deviceId): return .peerDisconnected(deviceId: deviceId)
            case .pairingPrompt(let conn, let peer, _):
                guard let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer.noisePublicKey) else {
                    // A peer whose static key is not a valid X25519 key cannot have completed Noise; refuse it.
                    return .close(conn: conn)
                }
                return .pairingPrompt(conn: conn, peer: Self.peerInfo(peer), publicKey: key)
            case .pairingPromptCancelled(let conn): return .pairingPromptCancelled(conn: conn)
            case .deliver(let envelope, let raw): return .deliver(Self.appEnvelope(envelope), raw: raw)
            case .heard(let deviceId): return .heard(deviceId: deviceId)
            case .trustChanged(let json): return .trustChanged(snapshotJSON: json)
            case .deviceRevoked(let deviceId): return .deviceRevoked(deviceId: deviceId)
            case .reconcileDue(let task, let peer): return .reconcileDue(task: task, peer: peer)
            case .relayConnect(let url): return .relayConnect(url: url)
            case .relaySendText(let text): return .relaySendText(text)
            case .relaySendBinary(let bytes): return .relaySendBinary(bytes)
            case .relayClose: return .relayClose
            case .relayJoined(let members): return .relayJoined(members: members)
            case .relayDown: return .relayDown
            case .relayError(let code): return .relayError(code: code)
            case .topicChanged(let secret, let epoch): return .topicChanged(secret: secret, epoch: epoch)
            }
        }
    }

    private static func peerInfo(_ peer: GossipCoreKit.PeerInfo) -> HandshakePeerInfo {
        HandshakePeerInfo(
            deviceId: peer.deviceId,
            deviceName: peer.deviceName,
            deviceType: DeviceType(rawValue: peer.deviceType) ?? .androidPhone,
            signingPublicKey: peer.signingPublicKey
        )
    }

    /// Payloads cross the boundary as JSON text; the app's `JSONValue` round-trips integers exactly (the protocol only
    /// allows integers, so a `Double` is lossless up to 2^53).
    static func coreEnvelope(_ e: Envelope) throws -> GossipCoreKit.Envelope {
        guard let json = try? String(data: JSONEncoder().encode(e.payload), encoding: .utf8) else {
            throw BridgeError.invalid("payload cannot be encoded")
        }
        return GossipCoreKit.Envelope(
            v: UInt32(e.v), id: e.id, kind: e.type, senderId: e.senderId, recipientId: e.recipientId,
            broadcast: e.broadcast, ttl: Int64(e.ttl), hasRawFollowup: e.hasRawFollowup, ts: e.ts, payloadJson: json, sig: e.sig
        )
    }

    static func appEnvelope(_ e: GossipCoreKit.Envelope) -> Envelope {
        let payload = (try? JSONDecoder().decode(JSONValue.self, from: Data(e.payloadJson.utf8))) ?? .object([:])
        return Envelope(
            id: e.id, type: e.kind, senderId: e.senderId, recipientId: e.recipientId, broadcast: e.broadcast,
            ttl: Int(e.ttl), hasRawFollowup: e.hasRawFollowup, ts: e.ts, payload: payload, sig: e.sig
        )
    }
}
