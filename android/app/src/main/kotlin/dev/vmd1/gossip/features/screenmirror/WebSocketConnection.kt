package dev.vmd1.gossip.features.screenmirror

import android.util.Base64
import java.io.Closeable
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.io.IOException
import java.net.Socket
import java.security.MessageDigest

/**
 * Minimal server-side RFC 6455 WebSocket over an already-accepted [Socket]: HTTP upgrade
 * handshake, masked client frames in, unmasked server frames out, ping/pong, close. Text and
 * binary messages, fragmentation reassembled, no extensions/compression. Deliberately tiny and
 * dependency-free — the screen bridge needs exactly "authenticated binary pipe to one viewer".
 *
 * Not thread-safe for concurrent reads; writes are synchronized so a video thread and a
 * device-message thread can both [sendBinary].
 */
class WebSocketConnection private constructor(
    private val socket: Socket,
    private val input: DataInputStream,
    private val output: DataOutputStream,
) : Closeable {
    class Message(val isText: Boolean, val data: ByteArray)

    private val writeLock = Any()

    /** Blocks for the next data message; answers pings, returns null on close/EOF. */
    fun readMessage(): Message? {
        var opcode = -1
        var assembled = java.io.ByteArrayOutputStream()
        while (true) {
            val b0 = try { input.readUnsignedByte() } catch (_: EOFException) { return null }
            val fin = b0 and 0x80 != 0
            val op = b0 and 0x0f
            val b1 = input.readUnsignedByte()
            if (b1 and 0x80 == 0) { close(1002); return null } // client frames must be masked
            var len = (b1 and 0x7f).toLong()
            if (len == 126L) len = input.readUnsignedShort().toLong()
            else if (len == 127L) len = input.readLong()
            if (len < 0 || len > MAX_MESSAGE) { close(1009); return null }
            val mask = ByteArray(4).also { input.readFully(it) }
            val payload = ByteArray(len.toInt()).also { input.readFully(it) }
            for (i in payload.indices) payload[i] = (payload[i].toInt() xor mask[i and 3].toInt()).toByte()
            when (op) {
                OP_PING -> writeFrame(OP_PONG, payload)
                OP_PONG -> Unit
                OP_CLOSE -> { runCatching { writeFrame(OP_CLOSE, payload.copyOf(minOf(2, payload.size))) }; return null }
                else -> {
                    if (op != OP_CONT) { opcode = op; assembled = java.io.ByteArrayOutputStream() }
                    if (assembled.size() + payload.size > MAX_MESSAGE) { close(1009); return null }
                    assembled.write(payload)
                    if (fin) return Message(opcode == OP_TEXT, assembled.toByteArray())
                }
            }
        }
    }

    fun sendBinary(data: ByteArray) = writeFrame(OP_BINARY, data)
    fun sendText(text: String) = writeFrame(OP_TEXT, text.toByteArray(Charsets.UTF_8))

    fun close(code: Int = 1000) {
        runCatching { writeFrame(OP_CLOSE, byteArrayOf((code shr 8).toByte(), code.toByte())) }
        runCatching { socket.close() }
    }

    override fun close() = close(1000)

    private fun writeFrame(op: Int, payload: ByteArray) = synchronized(writeLock) {
        output.writeByte(0x80 or op)
        when {
            payload.size < 126 -> output.writeByte(payload.size)
            payload.size <= 0xffff -> { output.writeByte(126); output.writeShort(payload.size) }
            else -> { output.writeByte(127); output.writeLong(payload.size.toLong()) }
        }
        output.write(payload)
        output.flush()
    }

    companion object {
        private const val OP_CONT = 0
        private const val OP_TEXT = 1
        private const val OP_BINARY = 2
        private const val OP_CLOSE = 8
        private const val OP_PING = 9
        private const val OP_PONG = 10
        private const val MAX_MESSAGE = 1L shl 20
        private const val GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

        /** Performs the HTTP upgrade on [socket]; throws [IOException] if it isn't a valid
         *  WebSocket upgrade request (a plain HTTP probe gets a 400 and the socket is closed). */
        fun accept(socket: Socket): WebSocketConnection {
            val input = DataInputStream(socket.getInputStream().buffered(64 * 1024))
            val output = DataOutputStream(socket.getOutputStream().buffered(64 * 1024))
            val headers = readHttpHeaders(input)
            val key = headers["sec-websocket-key"]
            if (!headers["upgrade"].equals("websocket", ignoreCase = true) || key == null) {
                output.write("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n".toByteArray())
                output.flush(); socket.close()
                throw IOException("not a websocket upgrade")
            }
            val accept = Base64.encodeToString(
                MessageDigest.getInstance("SHA-1").digest((key + GUID).toByteArray()), Base64.NO_WRAP
            )
            output.write(
                ("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
                    "Sec-WebSocket-Accept: $accept\r\n\r\n").toByteArray()
            )
            output.flush()
            return WebSocketConnection(socket, input, output)
        }

        private fun readHttpHeaders(input: DataInputStream): Map<String, String> {
            val sb = StringBuilder()
            while (!sb.endsWith("\r\n\r\n")) {
                sb.append(input.readUnsignedByte().toChar())
                if (sb.length > 8192) throw IOException("HTTP header too large")
            }
            return sb.lines().drop(1).mapNotNull { line ->
                val i = line.indexOf(':')
                if (i > 0) line.substring(0, i).trim().lowercase() to line.substring(i + 1).trim() else null
            }.toMap()
        }
    }
}
