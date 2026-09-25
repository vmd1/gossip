import Foundation
import CryptoKit

/// Implements the `trust.roster_update` / `trust.revoke` message types: gossips this
/// Mac's local `TrustedDevices` roster to the rest of the mesh so pairing with any one
/// existing member propagates to every other member automatically — nobody needs to
/// individually re-pair with every other device by hand. See
/// `docs/adr/0002-device-group-addressing.md` and the mesh-support ADR.
///
/// Trust is transitive and automatic: a gossiped entry for a device this Mac has never
/// paired with directly is merged straight into `TrustedDevicesStore`, with no user
/// confirmation prompt — justified because the gossip arrives over an already-Noise-
/// authenticated direct connection from an already-trusted device. Once trusted this
/// way, a subsequent direct Bonjour discovery of that device (or a fallback-host dial)
/// will connect to it normally; until then, messages still reach it via multi-hop
/// relay through whichever device it *is* gossiped through (see
/// `docs/wire-protocol.md`'s "Multi-hop relay" section).
final class RosterGossipManager {
    private let transportManager: TransportManager
    private let trustedDevices: TrustedDevicesStore
    private let identity = IdentityKeyStore.shared

    init(transportManager: TransportManager, trustedDevices: TrustedDevicesStore = .shared) {
        self.transportManager = transportManager
        self.trustedDevices = trustedDevices

        transportManager.router.register(prefix: "trust.roster_update") { [weak self] envelope in
            self?.handleRosterUpdate(envelope)
        }
        transportManager.router.register(prefix: "trust.revoke") { [weak self] envelope in
            self?.handleRevoke(envelope)
        }

        // Every fresh connection (a reconnect, or a freshly-confirmed pairing reaching
        // the same "connected" outcome) gets this Mac's current roster, targeted just
        // at them — the newly-connected peer is exactly who's missing the most
        // information.
        transportManager.addOnTrustedConnected { [weak self] peer in
            self?.sendRoster(to: peer.deviceId)
        }
        // A brand-new pairing (not a reconnect) is broadcast to everyone else already
        // connected, so the rest of the mesh learns about the new device without
        // waiting for the periodic resync. Flood-forwarding then carries it
        // transitively through the whole mesh for free.
        transportManager.addOnNewDevicePaired { [weak self] _ in
            self?.broadcastRoster()
        }
    }

    /// Re-broadcasts the full local roster to all connected peers — a self-healing
    /// backstop for dropped messages, mirroring the existing DND 60s-resync
    /// convention. Call periodically (e.g. every 5 minutes) while the app is running.
    func periodicResync() {
        broadcastRoster()
    }

    /// UI should call this instead of `TrustedDevicesStore.revoke` directly: revokes
    /// locally and broadcasts `trust.revoke` so the rest of the mesh drops trust for
    /// this device too, rather than caching it forever on any device that doesn't
    /// happen to talk to the revoker again.
    func revoke(deviceId: String) {
        trustedDevices.revoke(deviceId: deviceId)
        transportManager.disconnect(deviceId: deviceId)
        let envelope = Envelope(
            type: "trust.revoke",
            senderId: identity.deviceId,
            broadcast: true,
            payload: .object(["deviceId": .string(deviceId)])
        )
        try? transportManager.send(envelope: envelope)
    }

    // MARK: - Sending

    private func sendRoster(to recipientId: String) {
        let envelope = Envelope(
            type: "trust.roster_update",
            senderId: identity.deviceId,
            recipientId: recipientId,
            payload: rosterPayload()
        )
        try? transportManager.send(envelope: envelope)
    }

    private func broadcastRoster() {
        let envelope = Envelope(
            type: "trust.roster_update",
            senderId: identity.deviceId,
            broadcast: true,
            payload: rosterPayload()
        )
        try? transportManager.send(envelope: envelope)
    }

    /// Every device this Mac currently trusts, plus itself — a recipient meeting the
    /// mesh for the first time via a relayed broadcast (rather than a direct targeted
    /// send) needs to learn about the sender too, not just the sender's other peers.
    private func rosterPayload() -> JSONValue {
        var entries = trustedDevices.allDevices().map { device -> JSONValue in
            var fields: [String: JSONValue] = [
                "deviceId": .string(device.deviceId),
                "publicKey": .string(device.publicKeyBase64),
                "deviceName": .string(device.deviceName),
                "deviceType": .string(device.deviceType.rawValue)
            ]
            if let signingPublicKeyBase64 = device.signingPublicKeyBase64 {
                fields["signingPublicKey"] = .string(signingPublicKeyBase64)
            }
            return .object(fields)
        }
        entries.append(.object([
            "deviceId": .string(identity.deviceId),
            "publicKey": .string(identity.agreementKey.publicKey.rawRepresentation.base64EncodedString()),
            "deviceName": .string(Host.current().localizedName ?? "Mac"),
            "deviceType": .string(DeviceType.mac.rawValue),
            "signingPublicKey": .string(identity.signingKey.publicKey.rawRepresentation.base64EncodedString())
        ]))
        return .object(["devices": .array(entries)])
    }

    // MARK: - Receiving

    private func handleRosterUpdate(_ envelope: Envelope) {
        guard case .array(let entries) = envelope.payload["devices"] else { return }
        for entry in entries {
            guard let deviceId = entry["deviceId"]?.stringValue, deviceId != identity.deviceId else { continue }
            let signingPublicKey = entry["signingPublicKey"]?.stringValue
            // Never clobber an already-trusted device's own row (e.g. one paired
            // directly, or already gossiped) with a remote-reported copy — this
            // would otherwise re-stamp `addedAt` on every periodic resync. Narrow
            // exception: backfill a missing signing key (a row paired before that
            // field existed), since gossip is otherwise the only way that row would
            // ever learn it.
            if trustedDevices.isTrusted(deviceId: deviceId) {
                if let signingPublicKey {
                    trustedDevices.backfillSigningPublicKey(deviceId: deviceId, signingPublicKeyBase64: signingPublicKey)
                }
                continue
            }
            guard let publicKey = entry["publicKey"]?.stringValue,
                  let deviceName = entry["deviceName"]?.stringValue,
                  let deviceTypeRaw = entry["deviceType"]?.stringValue,
                  let deviceType = DeviceType(rawValue: deviceTypeRaw)
            else { continue }
            trustedDevices.addDevice(
                deviceId: deviceId,
                publicKeyBase64: publicKey,
                deviceName: deviceName,
                deviceType: deviceType,
                signingPublicKeyBase64: signingPublicKey
            )
        }
    }

    private func handleRevoke(_ envelope: Envelope) {
        guard let deviceId = envelope.payload["deviceId"]?.stringValue else { return }
        trustedDevices.revoke(deviceId: deviceId)
        transportManager.disconnect(deviceId: deviceId)
    }
}
