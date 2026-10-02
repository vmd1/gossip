package dev.vmd1.gossip.features.universalcontrol

import java.nio.ByteBuffer
import java.security.GeneralSecurityException
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

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

    fun encode(): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        fun u8(v: Int) = out.write(v and 0xff)
        fun u16(v: Int) { u8(v shr 8); u8(v) }
        fun display(d: ControlDisplayInfo) {
            u16(d.width.coerceIn(0, 65535)); u16(d.height.coerceIn(0, 65535))
            u8(d.rotation.coerceIn(0, 255)); u8(d.backend.coerceIn(0, 255))
        }
        when (this) {
            is Hello -> { u8(KIND_HELLO); out.write(sessionId.toByteArray(Charsets.UTF_8)) }
            is Enter -> { u8(KIND_ENTER); u8(edge.raw); u16(position) }
            Leave -> u8(KIND_LEAVE)
            is MouseMove -> { u8(KIND_MOUSE_MOVE); u16(dx); u16(dy) }
            is Buttons -> { u8(KIND_BUTTONS); u8(mask) }
            is Scroll -> { u8(KIND_SCROLL); u16(dx); u16(dy) }
            is Key -> { u8(KIND_KEY); u16(usage); u8(if (down) 1 else 0); u8(modifiers) }
            is Text -> { u8(KIND_TEXT); out.write(text.toByteArray(Charsets.UTF_8)) }
            Ping -> u8(KIND_PING)
            is CursorQuery -> { u8(KIND_CURSOR_QUERY); u8(token) }
            is Action -> { u8(KIND_ACTION); u8(action.raw) }
            is HelloAck -> { u8(KIND_HELLO_ACK); display(info) }
            is DisplayInfo -> { u8(KIND_DISPLAY_INFO); display(info) }
            is Error -> { u8(KIND_ERROR); out.write(reason.toByteArray(Charsets.UTF_8)) }
            Pong -> u8(KIND_PONG)
            is CursorPos -> { u8(KIND_CURSOR_POS); u8(token); u16(x.coerceIn(0, 65535)); u16(y.coerceIn(0, 65535)); u16((applied ushr 16).toInt()); u16(applied.toInt()) }
        }
        return out.toByteArray()
    }

    companion object {
        const val KIND_HELLO = 0x01
        const val KIND_ENTER = 0x10
        const val KIND_LEAVE = 0x11
        const val KIND_MOUSE_MOVE = 0x12
        const val KIND_BUTTONS = 0x13
        const val KIND_SCROLL = 0x14
        const val KIND_KEY = 0x15
        const val KIND_TEXT = 0x16
        const val KIND_PING = 0x17
        const val KIND_CURSOR_QUERY = 0x18
        const val KIND_ACTION = 0x19
        const val KIND_HELLO_ACK = 0x81
        const val KIND_DISPLAY_INFO = 0x82
        const val KIND_ERROR = 0x84
        const val KIND_PONG = 0x85
        const val KIND_CURSOR_POS = 0x86

        /** Returns null for an unknown kind or a malformed payload (the caller ignores it). */
        fun decode(data: ByteArray): ControlFrame? {
            if (data.isEmpty()) return null
            val b = ByteBuffer.wrap(data, 1, data.size - 1) // big-endian by default
            fun rest() = ByteArray(b.remaining()).also { b.get(it) }
            fun u8() = b.get().toInt() and 0xff
            fun u16() = b.short.toInt() and 0xffff
            fun i16() = b.short.toInt()
            fun display(): ControlDisplayInfo? =
                if (b.remaining() != 6) null else ControlDisplayInfo(u16(), u16(), u8(), u8())
            return try {
                when (data[0].toInt() and 0xff) {
                    KIND_HELLO -> Hello(String(rest(), Charsets.UTF_8))
                    KIND_ENTER -> if (b.remaining() != 3) null else ControlEdge.from(u8())?.let { Enter(it, u16()) }
                    KIND_LEAVE -> if (b.hasRemaining()) null else Leave
                    KIND_MOUSE_MOVE -> if (b.remaining() != 4) null else MouseMove(i16(), i16())
                    KIND_BUTTONS -> if (b.remaining() != 1) null else Buttons(u8())
                    KIND_SCROLL -> if (b.remaining() != 4) null else Scroll(i16(), i16())
                    KIND_KEY -> if (b.remaining() != 4) null else {
                        val usage = u16(); val down = u8(); val mods = u8()
                        if (down > 1) null else Key(usage, down == 1, mods)
                    }
                    KIND_TEXT -> Text(String(rest(), Charsets.UTF_8))
                    KIND_PING -> if (b.hasRemaining()) null else Ping
                    KIND_CURSOR_QUERY -> if (b.remaining() != 1) null else CursorQuery(u8())
                    KIND_ACTION -> if (b.remaining() != 1) null else ControlAction.from(u8())?.let { Action(it) }
                    KIND_HELLO_ACK -> display()?.let { HelloAck(it) }
                    KIND_DISPLAY_INFO -> display()?.let { DisplayInfo(it) }
                    KIND_ERROR -> Error(String(rest(), Charsets.UTF_8))
                    KIND_PONG -> if (b.hasRemaining()) null else Pong
                    KIND_CURSOR_POS -> if (b.remaining() != 9) null else CursorPos(u8(), u16(), u16(), (u16().toLong() shl 16) or u16().toLong())
                    else -> null
                }
            } catch (_: java.nio.BufferUnderflowException) { null }
        }
    }
}

/** One end of a session's cipher. Not thread-safe: own it from one thread (or synchronize). */
class ControlCipher(secret: ByteArray, private val sessionId: String, private val deviceSide: Boolean = true) {
    class Failure(message: String, val replayed: Boolean = false) : Exception(message)

    private val sendDirection = if (deviceSide) DIR_D2M else DIR_M2D
    private val receiveDirection = if (deviceSide) DIR_M2D else DIR_D2M
    private val sendKey = SecretKeySpec(hkdf(secret, sessionId.toByteArray(), info(sendDirection)), "ChaCha20")
    private val receiveKey = SecretKeySpec(hkdf(secret, sessionId.toByteArray(), info(receiveDirection)), "ChaCha20")
    private var sendCounter = 0L
    private var lastReceived = 0L

    fun seal(frame: ControlFrame): ByteArray {
        sendCounter += 1
        return seal(frame.encode(), sendCounter)
    }

    /** Exposed for the shared test vectors (fixed counter). */
    fun seal(plaintext: ByteArray, counter: Long): ByteArray {
        val c = newCipher()
        c.init(Cipher.ENCRYPT_MODE, sendKey, IvParameterSpec(nonce(counter)))
        c.updateAAD(aad(sendDirection))
        val sealed = c.doFinal(plaintext) // ciphertext || 16-byte tag
        return ByteBuffer.allocate(8 + sealed.size).putLong(counter).put(sealed).array()
    }

    /** Decrypts and authenticates [message]; throws [Failure] on a replay, a bad length or a forgery. */
    fun open(message: ByteArray): ControlFrame? {
        if (message.size < 8 + 16) throw Failure("bad length")
        val counter = ByteBuffer.wrap(message, 0, 8).long
        if (counter <= lastReceived) throw Failure("replayed", replayed = true)
        val plaintext = try {
            val c = newCipher()
            c.init(Cipher.DECRYPT_MODE, receiveKey, IvParameterSpec(nonce(counter)))
            c.updateAAD(aad(receiveDirection))
            c.doFinal(message, 8, message.size - 8)
        } catch (_: GeneralSecurityException) { throw Failure("authentication") }
        lastReceived = counter // only after authentication, so garbage can't burn counters
        return ControlFrame.decode(plaintext)
    }

    private fun aad(direction: Int): ByteArray =
        "gossip-control-v1".toByteArray() + byteArrayOf(direction.toByte()) + sessionId.toByteArray(Charsets.UTF_8)

    private fun nonce(counter: Long): ByteArray = ByteBuffer.allocate(12).putInt(0).putLong(counter).array()

    companion object {
        const val DIR_M2D = 1
        const val DIR_D2M = 2
        private fun info(direction: Int) =
            (if (direction == DIR_M2D) "gossip-control-v1 m2d" else "gossip-control-v1 d2m").toByteArray()

        /** HKDF-SHA256 (RFC 5869), one 32-byte output block. */
        internal fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray): ByteArray {
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(if (salt.isEmpty()) ByteArray(32) else salt, "HmacSHA256"))
            val prk = mac.doFinal(ikm)
            mac.init(SecretKeySpec(prk, "HmacSHA256"))
            mac.update(info); mac.update(1.toByte())
            return mac.doFinal()
        }
    }
}

/** JDK/BouncyCastle name first, Conscrypt's (Android) transformation string as the fallback. */
private fun newCipher(): Cipher =
    try { Cipher.getInstance("ChaCha20-Poly1305") } catch (_: GeneralSecurityException) { Cipher.getInstance("ChaCha20/Poly1305/NoPadding") }

/** Constant-time compare for the session id in the hello. */
internal fun constantTimeEquals(a: String, b: String): Boolean =
    MessageDigest.isEqual(a.toByteArray(Charsets.UTF_8), b.toByteArray(Charsets.UTF_8))
