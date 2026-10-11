package dev.vmd1.gossip.features.universalcontrol

import java.nio.ByteBuffer
import java.security.MessageDigest
import uniffi.gossip_ffi.ControlAction as CoreAction
import uniffi.gossip_ffi.ControlDisplayInfo as CoreInfo
import uniffi.gossip_ffi.ControlEdge as CoreEdge
import uniffi.gossip_ffi.ControlFrame as CoreFrame
import uniffi.gossip_ffi.StreamCipher
import uniffi.gossip_ffi.controlFrameDecode
import uniffi.gossip_ffi.controlFrameEncode
import uniffi.gossip_ffi.StreamProfile

/**
 * Kotlin twin of `mac/Gossip/Features/UniversalControl/ControlProtocol.swift`: the Universal Control data
 * channel. Both are checked against `schema/control-test-vectors.json`.
 *
 * Every WebSocket message is `[u64 BE counter][ChaCha20-Poly1305 ciphertext][16-byte tag]` where the key is
 * HKDF-SHA256(secret, salt = sessionId, info = "gossip-control-v1 m2d" | "d2m"), the nonce is 4 zero bytes +
 * the counter, and the AAD is "gossip-control-v1" + direction byte (1 = m2d, 2 = d2m) + sessionId.
 */
data class ControlDisplayInfo(val width: Int, val height: Int, val rotation: Int, val backend: Int)

enum class ControlAction(val raw: Int) {
    HOME(1), APP_SWITCH(2), NOTIFICATIONS(3), BACK(4);

    companion object { fun from(raw: Int) = values().firstOrNull { it.raw == raw } }
}

enum class ControlEdge(val raw: Int) {
    LEFT(0), RIGHT(1), TOP(2), BOTTOM(3);

    companion object { fun from(raw: Int) = values().firstOrNull { it.raw == raw } }
}

sealed class ControlFrame {
    // Mac -> device
    data class Hello(val sessionId: String) : ControlFrame()
    /** The cursor enters through [edge], [position] (0..65535) of the way along that edge. */
    data class Enter(val edge: ControlEdge, val position: Int) : ControlFrame()
    object Leave : ControlFrame() { override fun toString() = "Leave" }
    data class MouseMove(val dx: Int, val dy: Int) : ControlFrame()
    /** Bit 0 primary, 1 secondary, 2 middle, 3 back, 4 forward. */
    data class Buttons(val mask: Int) : ControlFrame()
    /** 1/120 of a notch; positive y = up, positive x = right. */
    data class Scroll(val dx: Int, val dy: Int) : ControlFrame()
    /** USB HID keyboard-page [usage]; [modifiers] is the HID modifier bitmask (LCtrl=1 ... RMeta=128). */
    data class Key(val usage: Int, val down: Boolean, val modifiers: Int) : ControlFrame()
    data class Text(val text: String) : ControlFrame()
    object Ping : ControlFrame() { override fun toString() = "Ping" }
    /** Asks for the real cursor position; answered with [CursorPos] carrying the same [token]. */
    data class CursorQuery(val token: Int) : ControlFrame()
    /** A system navigation action: 1 Home, 2 App Switcher, 3 Notifications, 4 Back (see [ControlAction]). */
    data class Action(val action: ControlAction) : ControlFrame()
    // device -> Mac
    data class HelloAck(val info: ControlDisplayInfo) : ControlFrame()
    data class DisplayInfo(val info: ControlDisplayInfo) : ControlFrame()
    data class Error(val reason: String) : ControlFrame()
    object Pong : ControlFrame() { override fun toString() = "Pong" }
    /** The real cursor position in this display's logical pixels, and how many `MouseMove`s had been applied since
     *  the last `Enter` when it was read ([applied], unsigned 32-bit). */
    data class CursorPos(val token: Int, val x: Int, val y: Int, val applied: Long) : ControlFrame()

    /** The wire bytes; the codec is the core's (`desktop/core/src/features/control.rs`), shared with every platform. */
    fun encode(): ByteArray = controlFrameEncode(toCore())

    private fun toCore(): CoreFrame {
        fun info(d: ControlDisplayInfo) = CoreInfo(
            d.width.coerceIn(0, 65535).toUShort(), d.height.coerceIn(0, 65535).toUShort(),
            d.rotation.coerceIn(0, 255).toUByte(), d.backend.coerceIn(0, 255).toUByte()
        )
        return when (this) {
            is Hello -> CoreFrame.Hello(sessionId)
            is Enter -> CoreFrame.Enter(
                when (edge) { ControlEdge.LEFT -> CoreEdge.LEFT; ControlEdge.RIGHT -> CoreEdge.RIGHT; ControlEdge.TOP -> CoreEdge.TOP; ControlEdge.BOTTOM -> CoreEdge.BOTTOM },
                position.coerceIn(0, 65535).toUShort()
            )
            Leave -> CoreFrame.Leave
            is MouseMove -> CoreFrame.MouseMove(dx.toShort(), dy.toShort())
            is Buttons -> CoreFrame.Buttons(mask.toUByte())
            is Scroll -> CoreFrame.Scroll(dx.toShort(), dy.toShort())
            is Key -> CoreFrame.Key(usage.toUShort(), down, modifiers.toUByte())
            is Text -> CoreFrame.Text(text)
            Ping -> CoreFrame.Ping
            is CursorQuery -> CoreFrame.CursorQuery(token.toUByte())
            is Action -> CoreFrame.Action(
                when (action) { ControlAction.HOME -> CoreAction.HOME; ControlAction.APP_SWITCH -> CoreAction.APP_SWITCH; ControlAction.NOTIFICATIONS -> CoreAction.NOTIFICATIONS; ControlAction.BACK -> CoreAction.BACK }
            )
            is HelloAck -> CoreFrame.HelloAck(info(info))
            is DisplayInfo -> CoreFrame.DisplayInfo(info(info))
            is Error -> CoreFrame.Error(reason)
            Pong -> CoreFrame.Pong
            is CursorPos -> CoreFrame.CursorPos(token.toUByte(), x.coerceIn(0, 65535).toUShort(), y.coerceIn(0, 65535).toUShort(), applied.toUInt())
        }
    }

    companion object {
        /** Returns null for an unknown kind or a malformed payload (the caller ignores it). */
        fun decode(data: ByteArray): ControlFrame? = controlFrameDecode(data)?.let(::fromCore)

        private fun fromCore(f: CoreFrame): ControlFrame {
            fun info(d: CoreInfo) = ControlDisplayInfo(d.width.toInt(), d.height.toInt(), d.rotation.toInt(), d.backend.toInt())
            return when (f) {
                is CoreFrame.Hello -> Hello(f.sessionId)
                is CoreFrame.Enter -> Enter(
                    when (f.edge) { CoreEdge.LEFT -> ControlEdge.LEFT; CoreEdge.RIGHT -> ControlEdge.RIGHT; CoreEdge.TOP -> ControlEdge.TOP; CoreEdge.BOTTOM -> ControlEdge.BOTTOM },
                    f.position.toInt()
                )
                CoreFrame.Leave -> Leave
                is CoreFrame.MouseMove -> MouseMove(f.dx.toInt(), f.dy.toInt())
                is CoreFrame.Buttons -> Buttons(f.mask.toInt())
                is CoreFrame.Scroll -> Scroll(f.dx.toInt(), f.dy.toInt())
                is CoreFrame.Key -> Key(f.usage.toInt(), f.down, f.modifiers.toInt())
                is CoreFrame.Text -> Text(f.text)
                CoreFrame.Ping -> Ping
                is CoreFrame.CursorQuery -> CursorQuery(f.token.toInt())
                is CoreFrame.Action -> Action(
                    when (f.action) { CoreAction.HOME -> ControlAction.HOME; CoreAction.APP_SWITCH -> ControlAction.APP_SWITCH; CoreAction.NOTIFICATIONS -> ControlAction.NOTIFICATIONS; CoreAction.BACK -> ControlAction.BACK }
                )
                is CoreFrame.HelloAck -> HelloAck(info(f.info))
                is CoreFrame.DisplayInfo -> DisplayInfo(info(f.info))
                is CoreFrame.Error -> Error(f.reason)
                CoreFrame.Pong -> Pong
                is CoreFrame.CursorPos -> CursorPos(f.token.toInt(), f.x.toInt(), f.y.toInt(), f.applied.toLong())
            }
        }
    }
}

/** One end of a session's cipher: the core's `StreamCipher` (`desktop/core/src/crypto/stream.rs`). Own it from one thread. */
class ControlCipher(secret: ByteArray, sessionId: String, deviceSide: Boolean = true) {
    class Failure(message: String, val replayed: Boolean = false) : Exception(message)

    private val inner = StreamCipher(StreamProfile.CONTROL, secret, sessionId, !deviceSide)

    fun seal(frame: ControlFrame): ByteArray = inner.seal(frame.encode())

    /** Decrypts and authenticates [message]; throws [Failure] on a replay, a bad length or a forgery. */
    fun open(message: ByteArray): ControlFrame? {
        val plaintext = try {
            inner.open(message)
        } catch (e: Exception) {
            val text = e.message.orEmpty()
            when {
                text.contains("too short") -> throw Failure("bad length")
                text.contains("not greater") -> throw Failure("replayed", replayed = true)
                else -> throw Failure("authentication")
            }
        }
        return ControlFrame.decode(plaintext)
    }
}

/** Constant-time compare for the session id in the hello. */
internal fun constantTimeEquals(a: String, b: String): Boolean =
    MessageDigest.isEqual(a.toByteArray(Charsets.UTF_8), b.toByteArray(Charsets.UTF_8))
