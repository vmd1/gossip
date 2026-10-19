package dev.vmd1.gossip.features.screenmirror

import android.util.Base64
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * Minimal client-side RFC 6455 WebSocket (the counterpart of [WebSocketConnection], which is the server side): HTTP
 * upgrade, masked frames out, unmasked frames in, ping/pong, close. Binary and text messages, fragmentation
 * reassembled, no extensions. Reads are single-threaded; writes are synchronized.
 */
class WebSocketClient private constructor(
    private val socket: Socket,
    private val input: DataInputStream,
    private val output: DataOutputStream,
) : Closeable {
    class Message(val isText: Boolean, val data: ByteArray)

    private val writeLock = Any()
    private val random = SecureRandom()

    /** Blocks for the next data message; answers pings, returns null on close/EOF. */
    fun readMessage(): Message? {
        var opcode = -1
        var assembled = ByteArrayOutputStream()
        while (true) {
            val b0 = try { input.readUnsignedByte() } catch (_: EOFException) { return null } catch (_: IOException) { return null }
            val fin = b0 and 0x80 != 0
            val op = b0 and 0x0f
            val b1 = input.readUnsignedByte()
            if (b1 and 0x80 != 0) { close(1002); return null } // server frames must not be masked
            var len = (b1 and 0x7f).toLong()
            if (len == 126L) len = input.readUnsignedShort().toLong()
            else if (len == 127L) len = input.readLong()
            if (len < 0 || len > MAX_MESSAGE) { close(1009); return null }
            val payload = ByteArray(len.toInt()).also { input.readFully(it) }
            when (op) {
                OP_PING -> writeFrame(OP_PONG, payload)
                OP_PONG -> Unit
                OP_CLOSE -> { runCatching { writeFrame(OP_CLOSE, payload.copyOf(minOf(2, payload.size))) }; return null }
                else -> {
                    if (op != OP_CONT) { opcode = op; assembled = ByteArrayOutputStream() }
                    if (assembled.size() + payload.size > MAX_MESSAGE) { close(1009); return null }
                    assembled.write(payload)
                    if (fin) return Message(opcode == OP_TEXT, assembled.toByteArray())
                }
            }
        }
    }

    fun sendBinary(data: ByteArray) = writeFrame(OP_BINARY, data)

    fun close(code: Int = 1000) {
        runCatching { writeFrame(OP_CLOSE, byteArrayOf((code shr 8).toByte(), code.toByte())) }
        runCatching { socket.close() }
    }

    override fun close() = close(1000)

    private fun writeFrame(op: Int, payload: ByteArray) = synchronized(writeLock) {
        val mask = ByteArray(4).also { random.nextBytes(it) }
        output.writeByte(0x80 or op)
        when {
            payload.size < 126 -> output.writeByte(0x80 or payload.size)
            payload.size <= 0xffff -> { output.writeByte(0x80 or 126); output.writeShort(payload.size) }
            else -> { output.writeByte(0x80 or 127); output.writeLong(payload.size.toLong()) }
        }
        output.write(mask)
        val masked = ByteArray(payload.size) { (payload[it].toInt() xor mask[it and 3].toInt()).toByte() }
        output.write(masked)
        output.flush()
    }

    companion object {
        private const val OP_CONT = 0
        private const val OP_TEXT = 1
        private const val OP_BINARY = 2
        private const val OP_CLOSE = 8
        private const val OP_PING = 9
        private const val OP_PONG = 10
        private const val MAX_MESSAGE = 8L shl 20
        private const val GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

        /** Connects and performs the HTTP upgrade; throws [IOException] if the server doesn't switch protocols. */
        fun connect(address: InetAddress, port: Int, path: String, timeoutMs: Int = 5_000): WebSocketClient {
            val socket = Socket()
            try {
                socket.tcpNoDelay = true
                socket.connect(InetSocketAddress(address, port), timeoutMs)
                val input = DataInputStream(socket.getInputStream().buffered(64 * 1024))
                val output = DataOutputStream(socket.getOutputStream().buffered(64 * 1024))
                val keyBytes = ByteArray(16).also { SecureRandom().nextBytes(it) }
                val key = Base64.encodeToString(keyBytes, Base64.NO_WRAP)
                val host = (address.hostAddress ?: "").let { if (it.contains(':')) "[$it]" else it }
                output.write(
                    ("GET $path HTTP/1.1\r\nHost: $host:$port\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
                        "Sec-WebSocket-Key: $key\r\nSec-WebSocket-Version: 13\r\n\r\n").toByteArray()
                )
                output.flush()
                val sb = StringBuilder()
                while (!sb.endsWith("\r\n\r\n")) {
                    sb.append(input.readUnsignedByte().toChar())
                    if (sb.length > 8192) throw IOException("HTTP header too large")
                }
                val lines = sb.lines()
                if (!lines.first().contains(" 101")) throw IOException("upgrade refused: ${lines.first()}")
                val headers = lines.drop(1).mapNotNull { line ->
                    val i = line.indexOf(':')
                    if (i > 0) line.substring(0, i).trim().lowercase() to line.substring(i + 1).trim() else null
                }.toMap()
                val expected = Base64.encodeToString(
                    MessageDigest.getInstance("SHA-1").digest((key + GUID).toByteArray()), Base64.NO_WRAP
                )
                if (headers["sec-websocket-accept"] != expected) throw IOException("bad Sec-WebSocket-Accept")
                socket.soTimeout = 0
                return WebSocketClient(socket, input, output)
            } catch (t: Throwable) {
                runCatching { socket.close() }
                throw t
            }
        }
    }
}
