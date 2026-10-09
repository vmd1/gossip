import Foundation

/// The app-facing side of `trust.roster_update` / `trust.revoke`.
///
/// The protocol work moved into the Rust engine (`desktop/core`): it merges gossiped rosters (skipping devices it already
/// trusts, devices with a revocation tombstone, invalid keys and unknown device types, and capping both the entries per
/// message and the total), applies revocations (clamping `revokedAt`, dropping the connection), replies to a peer that
/// still introduces a revoked device, and decides when the roster is due (on every fresh connection and every five
/// minutes). When its trust changes it reports a snapshot, which `TransportManager` applies to `TrustedDevicesStore`.
/// See `docs/wire-protocol.md` and `schema/message-types.md`.
///
/// What is left here is the one thing the engine cannot know: when a brand-new pairing happened, so the rest of the
/// mesh learns about the new device now instead of at the next resync, and the UI's "Forget" action.
final class RosterGossipManager {
    private let transportManager: TransportManager

    init(transportManager: TransportManager) {
        self.transportManager = transportManager

        // A brand-new pairing (not a reconnect) is broadcast to everyone else already
        // connected, so the rest of the mesh learns about the new device without
        // waiting for the periodic resync. Flood-forwarding then carries it
        // transitively through the whole mesh for free.
        transportManager.addOnNewDevicePaired { [weak self] _ in
            self?.transportManager.sendRoster(to: nil)
        }
    }

    /// UI should call this instead of `TrustedDevicesStore.revoke` directly: the engine revokes locally, drops the
    /// connection and broadcasts `trust.revoke` so the rest of the mesh drops trust for this device too, rather than
    /// caching it forever on any device that doesn't happen to talk to the revoker again.
    func revoke(deviceId: String) {
        transportManager.revokeDevice(deviceId)
    }

    /// Roster limits, kept in step with the engine's (`desktop/core` `trust.rs`).
    static func isValidKey(_ base64: String) -> Bool { Data(base64Encoded: base64)?.count == 32 }
}
