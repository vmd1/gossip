package dev.vmd1.gossip.features.screenmirror

import uniffi.gossip_ffi.StreamCipher
import uniffi.gossip_ffi.StreamProfile

/**
 * Encrypts the screen-mirroring WebSocket (the Mac's `ScreenBridgeClient` is the other end). The construction (HKDF-derived
 * directional ChaCha20-Poly1305 keys, an 8-byte strictly increasing counter nonce, AAD binding direction and session id) is
 * the core's `StreamCipher` (`desktop/core/src/crypto/stream.rs`), shared with every platform and checked against
 * `schema/screen-cipher-vectors.json` there. The per-session `secret` travels only in the Noise-encrypted `screen.ready`.
 * Thread-safe.
 */
class ScreenCipher(secret: ByteArray, sessionId: String, deviceSide: Boolean = true) {
    class Failure(message: String) : Exception(message)

    private val inner = StreamCipher(StreamProfile.SCREEN, secret, sessionId, !deviceSide)

    fun seal(plaintext: ByteArray): ByteArray = inner.seal(plaintext)

    /** Decrypts and authenticates [message]; throws [Failure] on a replay, a bad length or a forgery. */
    fun open(message: ByteArray): ByteArray = try {
        inner.open(message)
    } catch (e: Exception) {
        throw Failure(e.message ?: "authentication")
    }
}
