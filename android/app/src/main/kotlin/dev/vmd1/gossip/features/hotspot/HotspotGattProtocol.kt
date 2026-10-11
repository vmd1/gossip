package dev.vmd1.gossip.features.hotspot

import uniffi.gossip_ffi.HotspotChunkReassembler
import uniffi.gossip_ffi.HotspotCredentials
import uniffi.gossip_ffi.HotspotStatus
import uniffi.gossip_ffi.HotspotToggleRequest
import uniffi.gossip_ffi.hotspotDeriveSharedKey
import uniffi.gossip_ffi.hotspotEncodeChunks
import uniffi.gossip_ffi.hotspotRequestCreate
import uniffi.gossip_ffi.hotspotRequestDecode
import uniffi.gossip_ffi.hotspotRequestEncode
import uniffi.gossip_ffi.hotspotRequestIsFresh
import uniffi.gossip_ffi.hotspotRequestVerify
import uniffi.gossip_ffi.hotspotStatusCreate
import uniffi.gossip_ffi.hotspotStatusDecode
import uniffi.gossip_ffi.hotspotStatusDecrypt
import uniffi.gossip_ffi.hotspotStatusEncode
import uniffi.gossip_ffi.hotspotStatusVerify
import java.security.SecureRandom
import java.util.UUID

/**
 * Wire-level contract for Instant Hotspot's BLE GATT control channel (`docs/ble-hotspot-protocol.md`). It travels over a raw
 * GATT service, not the Noise-encrypted mesh, since the point of Instant Hotspot is reaching a device with no IP
 * connectivity at all.
 *
 * The codec itself (the UUIDs, chunking, the signed request and status payloads, the AES-GCM credential blob, the
 * shared-key derivation and the replay/rate gate) is the core's (`desktop/core/src/features/hotspot_gatt.rs`), shared byte
 * for byte with the Mac; this object keeps the app-facing types and delegates to it.
 */
object HotspotGattProtocol {
    val SERVICE_UUID: UUID = UUID.fromString(uniffi.gossip_ffi.hotspotServiceUuid())
    val REQUEST_CHARACTERISTIC_UUID: UUID = UUID.fromString(uniffi.gossip_ffi.hotspotRequestCharacteristicUuid())
    val RESPONSE_CHARACTERISTIC_UUID: UUID = UUID.fromString(uniffi.gossip_ffi.hotspotResponseCharacteristicUuid())
    /** Client Characteristic Configuration Descriptor: standard Bluetooth base UUID, needed to enable notifications. */
    val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    /** Payload bytes per GATT write/notify chunk (never depends on MTU negotiation). */
    const val CHUNK_PAYLOAD_SIZE = 19

    /** Requests and responses are a few hundred bytes; anything larger is not a real message. */
    const val MAX_MESSAGE_BYTES = 4096

    /** A request older (or further in the future) than this is rejected, so a captured one can't be replayed later. */
    const val REQUEST_FRESHNESS_MS = 2 * 60_000L

    fun encodeChunks(message: ByteArray): List<ByteArray> = hotspotEncodeChunks(message)

    /** Reassembles chunks written/notified one at a time; anything over [MAX_MESSAGE_BYTES] is discarded. */
    class ChunkReassembler {
        private val core = HotspotChunkReassembler()

        /** The complete message once the last chunk arrives, or null if more are expected. */
        fun feed(chunk: ByteArray): ByteArray? = core.feed(chunk)
    }

    data class ToggleRequestPayload(
        val id: String,
        val en: Boolean,
        val n: String,
        /** Requester's clock, Unix ms, signed: bounds how long a captured request stays replayable. */
        val t: Long = 0L,
        val s: String
    ) {
        companion object {
            /** Builds and signs a fresh request. [privateKeySeed] is the raw 32-byte Ed25519 seed. */
            fun create(requesterId: String, enable: Boolean, privateKeySeed: ByteArray): ToggleRequestPayload {
                val core = hotspotRequestCreate(requesterId, enable, UUID.randomUUID().toString(), System.currentTimeMillis(), privateKeySeed)
                return ToggleRequestPayload(core.id, core.en, core.n, core.t, core.s)
            }
        }

        internal fun toCore() = HotspotToggleRequest(id, en, n, t, s)

        fun isSignatureValid(signingPublicKey: ByteArray): Boolean = hotspotRequestVerify(toCore(), b64(signingPublicKey))

        fun isFresh(nowMs: Long = System.currentTimeMillis()): Boolean = hotspotRequestIsFresh(toCore(), nowMs)
    }

    /**
     * [cred], when present, is base64(12-byte AES-GCM nonce || ciphertext+tag) encrypting the SSID and passphrase. Signed
     * over the *ciphertext*, so the signature also protects its integrity end to end.
     */
    data class StatusPayload(
        val id: String,
        val ok: Boolean,
        val n: String,
        val s: String,
        val cred: String? = null
    ) {
        companion object {
            fun create(
                providerId: String,
                enabled: Boolean,
                nonce: String,
                privateKeySeed: ByteArray,
                sharedSecretKey: ByteArray? = null,
                ssid: String? = null,
                passphrase: String? = null
            ): StatusPayload {
                val credentials = if (ssid != null && passphrase != null && sharedSecretKey != null) {
                    HotspotCredentials(ssid, passphrase, sharedSecretKey, ByteArray(12).also { SecureRandom().nextBytes(it) })
                } else null
                val core = hotspotStatusCreate(providerId, enabled, nonce, privateKeySeed, credentials)
                return StatusPayload(core.id, core.ok, core.n, core.s, core.cred)
            }
        }

        internal fun toCore() = HotspotStatus(id, ok, n, s, cred)

        fun isSignatureValid(signingPublicKey: ByteArray): Boolean = hotspotStatusVerify(toCore(), b64(signingPublicKey))

        /** Null if there was no credential blob or decryption fails. Callers must check [isSignatureValid] first. */
        fun decryptCredentials(sharedSecretKey: ByteArray): Pair<String, String>? {
            if (cred == null) return null
            return runCatching { hotspotStatusDecrypt(toCore(), sharedSecretKey) }.getOrNull()?.let { it.ssid to it.passphrase }
        }
    }

    /** `SHA-256(DH(local, remote) || "connect-hotspot-gatt-v1")`; null for a degenerate peer key. */
    fun deriveSharedSecretKey(localX25519PrivateKey: ByteArray, remoteX25519PublicKey: ByteArray): ByteArray? =
        runCatching { hotspotDeriveSharedKey(localX25519PrivateKey, remoteX25519PublicKey) }.getOrNull()

    fun encodeRequest(payload: ToggleRequestPayload): ByteArray = hotspotRequestEncode(payload.toCore())

    fun decodeRequest(bytes: ByteArray): ToggleRequestPayload? =
        hotspotRequestDecode(bytes)?.let { ToggleRequestPayload(it.id, it.en, it.n, it.t, it.s) }

    fun encodeStatus(payload: StatusPayload): ByteArray = hotspotStatusEncode(payload.toCore())

    fun decodeStatus(bytes: ByteArray): StatusPayload? =
        hotspotStatusDecode(bytes)?.let { StatusPayload(it.id, it.ok, it.n, it.s, it.cred) }

    private fun b64(bytes: ByteArray): String = java.util.Base64.getEncoder().encodeToString(bytes)
}
