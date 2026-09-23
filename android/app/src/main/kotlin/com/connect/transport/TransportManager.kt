package com.connect.transport

import android.content.Context
import android.os.Build
import android.util.Base64
import android.util.Log
import com.connect.crypto.IdentityKeyStore
import com.connect.crypto.NoiseRole
import com.connect.crypto.NoiseSession
import com.connect.crypto.TrustedDevicesStore
import com.connect.protocol.DeviceType
import com.connect.protocol.Envelope
import com.connect.protocol.HandshakePayload
import com.connect.protocol.MessageType
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.net.ServerSocket
import java.net.Socket

private const val TAG = "TransportManager"

enum class ConnectionState { DISCONNECTED, DISCOVERING, HANDSHAKING, CONNECTED }

/**
 * Owns the connection lifecycle to the paired peer: drives [NsdDiscovery] to find/advertise
 * a peer, opens a raw [Socket], performs the Noise_IK handshake via [NoiseSession] before
 * ever marking the link CONNECTED, and frames/deframes envelopes per the wire protocol —
 * `[4-byte big-endian length][payload]`.
 *
 * `handshake.hello` / `handshake.ack` envelopes are the one pair sent as plaintext JSON
 * (no Noise transport key exists yet); their payload carries the raw Noise_IK handshake
 * message bytes, base64-encoded, alongside `deviceName`/`deviceType`. Every envelope
 * after the handshake completes is Noise-encrypted ciphertext.
 */
class TransportManager(
    private val context: Context,
    val identityKeyStore: IdentityKeyStore,
    private val trustedDevicesStore: TrustedDevicesStore,
    val messageRouter: MessageRouter,
    private val deviceName: String = Build.MODEL ?: "Android device"
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val writeMutex = Mutex()

    private val _connectionState = MutableStateFlow(ConnectionState.DISCONNECTED)
    val connectionState: StateFlow<ConnectionState> = _connectionState.asStateFlow()

    private val _incoming = MutableSharedFlow<Envelope>(extraBufferCapacity = 64)
    val incoming: SharedFlow<Envelope> = _incoming.asSharedFlow()

    val discovery = NsdDiscovery(context, identityKeyStore.deviceId, identityKeyStore.publicKeyFingerprint())

    @Volatile private var socket: Socket? = null
    @Volatile private var output: DataOutputStream? = null
    @Volatile private var noiseSession: NoiseSession? = null
    @Volatile private var remoteDeviceId: String? = null
    private var serverSocket: ServerSocket? = null
    private var connectionJob: Job? = null

    /** When set, the *next* successfully decrypted post-handshake frame is
     *  delivered here as raw bytes instead of being parsed as an [Envelope],
     *  then cleared (one-shot). This is the receive side of the `file.chunk`
     *  convention (see `schema/message-types.md`): a feature module arms
     *  this synchronously from its `file.chunk` envelope handler, since that
     *  envelope is always immediately followed by exactly one raw binary
     *  frame on the wire — the connection loop below drains frames strictly
     *  in order, so as long as the handler is invoked (and this armed)
     *  before the loop reads the next frame, there's no race. */
    @Volatile private var pendingRawFrameHandler: ((ByteArray) -> Unit)? = null

    /** Arms [pendingRawFrameHandler]; see its doc for the ordering guarantee this relies on. */
    fun setPendingRawFrameHandler(handler: (ByteArray) -> Unit) {
        pendingRawFrameHandler = handler
    }

    /** Listens for incoming connections (e.g. a previously-paired Mac reconnecting) and
     *  advertises this device over NSD so a Mac running discovery can find it.
     *
     *  Binding is retried rather than thrown synchronously: this is called unconditionally
     *  from `SyncForegroundService.onStartCommand`, and a just-killed previous instance of
     *  this same service (e.g. `am force-stop` racing the system's own `START_STICKY`
     *  restart, observed directly in testing) can leave the port transiently unavailable
     *  for a moment even though nothing is genuinely still using it — an uncaught
     *  `BindException` there previously crashed the whole app on a race that clears
     *  itself within milliseconds. */
    fun listen(port: Int = DEFAULT_PORT) {
        stopListening()
        scope.launch {
            val server = bindServerSocket(port) ?: return@launch
            serverSocket = server
            discovery.startAdvertising(deviceName, server.localPort)
            while (!server.isClosed) {
                val client = try {
                    server.accept()
                } catch (e: IOException) {
                    if (server.isClosed) break else continue
                }
                launchConnectionLoop(client, role = NoiseRole.RESPONDER, remoteStaticPublicKey = null)
            }
        }
    }

    private suspend fun bindServerSocket(port: Int): ServerSocket? {
        repeat(LISTEN_BIND_ATTEMPTS) { attempt ->
            try {
                return ServerSocket(port)
            } catch (e: IOException) {
                Log.w(TAG, "Failed to bind listen port $port (attempt ${attempt + 1}/$LISTEN_BIND_ATTEMPTS)", e)
                delay(LISTEN_BIND_RETRY_DELAY_MS)
            }
        }
        Log.e(TAG, "Giving up binding listen port $port after $LISTEN_BIND_ATTEMPTS attempts")
        return null
    }

    fun stopListening() {
        discovery.stopAdvertising()
        runCatching { serverSocket?.close() }
        serverSocket = null
    }

    /**
     * Initiates an outbound connection to a peer at [host]:[port] using
     * [remoteStaticPublicKey] — known out-of-band from the pairing QR code — to run the
     * Noise_IK handshake as the initiator.
     */
    fun connect(host: String, port: Int, remoteStaticPublicKey: ByteArray) {
        _connectionState.value = ConnectionState.DISCOVERING
        scope.launch {
            val client = try {
                Socket(host, port)
            } catch (e: IOException) {
                Log.w(TAG, "Connect to $host:$port failed", e)
                _connectionState.value = ConnectionState.DISCONNECTED
                return@launch
            }
            launchConnectionLoop(client, role = NoiseRole.INITIATOR, remoteStaticPublicKey = remoteStaticPublicKey)
        }
    }

    /** Encrypts and frames [envelope], sending it over the active connection.
     *
     *  Encryption *and* the write must both happen inside [writeMutex]: `CipherState`'s
     *  nonce counter is a plain, unsynchronized `var`. `ClipboardSyncManager`,
     *  `NotificationListenerImpl`, `MediaControlBridge`, `DndSyncManager`, and
     *  `FileTransferManager` can all call `send`/`sendRawFrame` concurrently from
     *  different coroutines — encrypting outside the lock (the bug this replaces) let
     *  two calls race on the same nonce, or let a write land on the wire out of order
     *  relative to the nonce it was encrypted with. The receiver's AEAD nonce only
     *  advances on a *successful* decrypt, so one corrupted frame permanently desyncs
     *  the cipher and every message after it fails to decrypt for the rest of the
     *  connection (mirrors the equivalent bug just fixed on the Mac side).
     *
     *  Also always hops onto [Dispatchers.IO] itself, rather than trusting the caller's
     *  scope: the actual socket write is blocking, and several callers (`DndSyncManager`,
     *  `ClipboardSyncManager`) are constructed with `SyncForegroundService`'s
     *  `Dispatchers.Main` scope, which throws `NetworkOnMainThreadException` here
     *  otherwise. `NotificationListenerImpl`/`FileTransferManager` happen to use their
     *  own IO-dispatched scopes today, but nothing should have to know that to call this
     *  safely. */
    suspend fun send(envelope: Envelope) = withContext(Dispatchers.IO) {
        writeMutex.withLock {
            val session = noiseSession ?: throw IllegalStateException("Not connected")
            val out = output ?: throw IllegalStateException("Not connected")
            val ciphertext = session.encryptTransportMessage(envelope.encode())
            writeFrame(out, ciphertext)
        }
    }

    /** Encrypts and frames [data] exactly like [send], except the plaintext is raw
     *  bytes rather than a JSON envelope. Used for the binary half of the `file.chunk`
     *  convention (see `schema/message-types.md`): callers must send the matching
     *  `file.chunk` metadata envelope via [send] immediately before calling this, and
     *  only ever one raw frame per metadata frame. See [send]'s doc for why encryption
     *  must happen inside [writeMutex], not just the write. Also hops onto
     *  [Dispatchers.IO] itself — see [send]'s doc for why. */
    suspend fun sendRawFrame(data: ByteArray) = withContext(Dispatchers.IO) {
        writeMutex.withLock {
            val session = noiseSession ?: throw IllegalStateException("Not connected")
            val out = output ?: throw IllegalStateException("Not connected")
            val ciphertext = session.encryptTransportMessage(data)
            writeFrame(out, ciphertext)
        }
    }

    fun currentRemoteDeviceId(): String? = remoteDeviceId

    fun disconnect() {
        connectionJob?.cancel()
        runCatching { socket?.close() }
        socket = null
        output = null
        noiseSession = null
        remoteDeviceId = null
        _connectionState.value = ConnectionState.DISCONNECTED
    }

    fun shutdown() {
        disconnect()
        stopListening()
        scope.cancel()
    }

    private fun launchConnectionLoop(client: Socket, role: NoiseRole, remoteStaticPublicKey: ByteArray?) {
        connectionJob = scope.launch {
            var connectedSocket: Socket? = null
            try {
                _connectionState.value = ConnectionState.HANDSHAKING
                val input = DataInputStream(client.getInputStream())
                val out = DataOutputStream(client.getOutputStream())

                val session = NoiseSession(role, identityKeyStore.x25519KeyPair, remoteStaticPublicKey)
                val remoteId = if (role == NoiseRole.INITIATOR) {
                    performInitiatorHandshake(session, out, input)
                } else {
                    performResponderHandshake(session, out, input)
                }

                connectedSocket = client
                socket = client
                output = out
                noiseSession = session
                remoteDeviceId = remoteId
                _connectionState.value = ConnectionState.CONNECTED
                Log.i(TAG, "Connected ($role) to device $remoteId")

                sendPresence(MessageType.PRESENCE_ONLINE, remoteId)

                while (true) {
                    val frame = readFrame(input)
                    val plaintext = session.decryptTransportMessage(frame)

                    val rawHandler = pendingRawFrameHandler
                    if (rawHandler != null) {
                        pendingRawFrameHandler = null
                        rawHandler(plaintext)
                        continue
                    }

                    val envelope = Envelope.decode(plaintext)
                    _incoming.emit(envelope)
                    messageRouter.dispatch(envelope)
                }
            } catch (e: Exception) {
                Log.w(TAG, "Connection loop ended: ${e.message}")
            } finally {
                runCatching { client.close() }
                if (connectedSocket == null || socket === connectedSocket) {
                    socket = null
                    output = null
                    noiseSession = null
                    remoteDeviceId = null
                    _connectionState.value = ConnectionState.DISCONNECTED
                }
            }
        }
    }

    private fun performInitiatorHandshake(session: NoiseSession, out: DataOutputStream, input: DataInputStream): String {
        val message1 = session.writeMessage1(ByteArray(0))
        val helloEnvelope = Envelope(
            type = MessageType.HANDSHAKE_HELLO,
            senderId = identityKeyStore.deviceId,
            payload = HandshakePayload(
                noise = Base64.encodeToString(message1, Base64.NO_WRAP),
                deviceName = deviceName,
                deviceType = DeviceType.ANDROID_PHONE.wireValue
            ).toJsonObject()
        )
        writeFrame(out, helloEnvelope.encode())

        val ackBytes = readFrame(input)
        val ackEnvelope = Envelope.decode(ackBytes)
        require(ackEnvelope.type == MessageType.HANDSHAKE_ACK) { "Expected handshake.ack, got ${ackEnvelope.type}" }
        val ackPayload = HandshakePayload.fromJsonObject(ackEnvelope.payload)
        val message2 = Base64.decode(ackPayload.noise, Base64.NO_WRAP)
        session.readMessage2(message2)
        return ackEnvelope.senderId
    }

    private fun performResponderHandshake(session: NoiseSession, out: DataOutputStream, input: DataInputStream): String {
        val helloBytes = readFrame(input)
        val helloEnvelope = Envelope.decode(helloBytes)
        require(helloEnvelope.type == MessageType.HANDSHAKE_HELLO) { "Expected handshake.hello, got ${helloEnvelope.type}" }
        val helloPayload = HandshakePayload.fromJsonObject(helloEnvelope.payload)
        val message1 = Base64.decode(helloPayload.noise, Base64.NO_WRAP)
        session.readMessage1(message1)

        val message2 = session.writeMessage2(ByteArray(0))
        val ackEnvelope = Envelope(
            type = MessageType.HANDSHAKE_ACK,
            senderId = identityKeyStore.deviceId,
            recipientId = helloEnvelope.senderId,
            payload = HandshakePayload(
                noise = Base64.encodeToString(message2, Base64.NO_WRAP),
                deviceName = deviceName,
                deviceType = DeviceType.ANDROID_PHONE.wireValue
            ).toJsonObject()
        )
        writeFrame(out, ackEnvelope.encode())
        return helloEnvelope.senderId
    }

    private suspend fun sendPresence(type: String, recipientId: String) {
        val envelope = Envelope(
            type = type,
            senderId = identityKeyStore.deviceId,
            recipientId = recipientId,
            payload = JsonObject(emptyMap())
        )
        runCatching { send(envelope) }
    }

    companion object {
        const val DEFAULT_PORT = 7913
        private const val MAX_FRAME_BYTES = 16 * 1024 * 1024
        private const val LISTEN_BIND_ATTEMPTS = 5
        private const val LISTEN_BIND_RETRY_DELAY_MS = 500L

        private fun writeFrame(out: DataOutputStream, payload: ByteArray) {
            out.writeInt(payload.size)
            out.write(payload)
            out.flush()
        }

        private fun readFrame(input: DataInputStream): ByteArray {
            val length = input.readInt()
            require(length in 0..MAX_FRAME_BYTES) { "Invalid frame length $length" }
            val buffer = ByteArray(length)
            input.readFully(buffer)
            return buffer
        }
    }
}
