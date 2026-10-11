package dev.vmd1.gossip.features.trust

import dev.vmd1.gossip.transport.TransportManager

/**
 * The app-facing side of `trust.roster_update` / `trust.revoke`.
 *
 * The protocol work moved into the Rust engine (`desktop/core`): it merges gossiped rosters (skipping devices it already
 * trusts, devices with a revocation tombstone, invalid keys and unknown device types, never announcing a provisional
 * pairing, and capping both the entries per message and the total), applies revocations (clamping `revokedAt`,
 * dropping the connection), replies to a peer that still introduces a revoked device, and decides when the roster is
 * due (on every fresh connection and every five minutes). When its trust changes it reports a snapshot, which
 * [TransportManager] applies to [dev.vmd1.gossip.crypto.TrustedDevicesStore]. See `docs/wire-protocol.md` and
 * `schema/message-types.md`.
 *
 * Trust is transitive and automatic: a gossiped entry for a device this device has never paired with directly is merged
 * straight into the store, with no user confirmation prompt — justified because the gossip arrives over an already
 * Noise-authenticated direct connection from an already-trusted device.
 *
 * What is left here is the one thing the engine cannot know: when a brand-new pairing happened (so the mesh learns about
 * the new device now instead of at the next resync), and the UI's "Forget" action.
 */
class RosterGossipManager(private val transportManager: TransportManager) {

    init {
        // A brand-new pairing completed via the *responder* role (this device showed a QR and an untrusted peer just
        // confirmed) — broadcast to the rest of the mesh. `announceNewDevice()` is called explicitly by
        // `PairingViewModel` for the *initiator*-role/QR-scan flow instead.
        transportManager.onNewDevicePaired = { announceNewDevice() }
    }

    /** Call right after adding a brand-new device to the trust table via pairing (not a reconnect) — broadcasts the
     *  updated roster to the rest of the mesh so it learns about the new device without waiting for the periodic
     *  resync. Flood-forwarding then carries it transitively through the whole mesh for free. */
    fun announceNewDevice() {
        transportManager.sendRoster(null)
    }

    /** UI should call this instead of [dev.vmd1.gossip.crypto.TrustedDevicesStore.revoke] directly: the engine revokes
     *  locally, drops the connection and broadcasts `trust.revoke` so the rest of the mesh drops trust (and any live
     *  connection) for this device too, rather than caching it forever on any device that doesn't happen to talk to
     *  the revoker again. */
    fun revoke(deviceId: String) {
        transportManager.revokeDevice(deviceId)
    }

    companion object {
        fun isUuid(value: String): Boolean = runCatching { java.util.UUID.fromString(value) }.isSuccess && value.length == 36

        /** A base64 32-byte key (X25519 / Ed25519), or null if it isn't one. */
        fun decodeKey(base64: String?): ByteArray? =
            base64?.let { runCatching { java.util.Base64.getDecoder().decode(it) }.getOrNull() }?.takeIf { it.size == 32 }
    }
}
