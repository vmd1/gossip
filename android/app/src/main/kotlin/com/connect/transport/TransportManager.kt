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

    /** Updated on every successfully-decrypted frame (any type, not just heartbeats) in
     *  [launchConnectionLoop]'s receive loop — see [heartbeatLoop]'s doc for why this exists. */
    @Volatile private var lastReceivedAt: Long = 0L

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
     *  `NotificationListenerImpl`, `MediaControlBridge`, and `DndSyncManager` can all call
     *  `send` concurrently from different coroutines — encrypting outside the lock (the bug
     *  this replaces) let two calls race on the same nonce, or let a write land on the wire
     *  out of order relative to the nonce it was encrypted with. The receiver's AEAD nonce
     *  only advances on a *successful* decrypt, so one corrupted frame permanently desyncs
     *  the cipher and every message after it fails to decrypt for the rest of the
     *  connection (mirrors the equivalent bug just fixed on the Mac side).
     *
     *  Also always hops onto [Dispatchers.IO] itself, rather than trusting the caller's
     *  scope: the actual socket write is blocking, and several callers (`DndSyncManager`,
     *  `ClipboardSyncManager`) are constructed with `SyncForegroundService`'s
     *  `Dispatchers.Main` scope, which throws `NetworkOnMainThreadException` here
     *  otherwise. `NotificationListenerImpl` happens to use its own IO-dispatched scope
     *  today, but nothing should have to know that to call this safely. */
    suspend fun send(envelope: Envelope) = withContext(Dispatchers.IO) {
        writeMutex.withLock {
            val session = noiseSession ?: throw IllegalStateException("Not connected")
            val out = output ?: throw IllegalStateException("Not connected")
            val ciphertext = session.encryptTransportMessage(envelope.encode())
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
                lastReceivedAt = System.currentTimeMillis()

                sendPresence(MessageType.PRESENCE_ONLINE, remoteId)
                val heartbeatJob = scope.launch { heartbeatLoop(client, remoteId) }

                try {
                    while (true) {
                        val frame = readFrame(input)
                        val plaintext = session.decryptTransportMessage(frame)
                        lastReceivedAt = System.currentTimeMillis()

                        val envelope = Envelope.decode(plaintext)
                        _incoming.emit(envelope)
                        messageRouter.dispatch(envelope)
                    }
                } finally {
                    heartbeatJob.cancel()
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

    /** Detects a *silently* dropped connection — the case a clean TCP close doesn't cover.
     *  The receive loop's `readFrame` blocks on the socket and throws promptly when the
     *  peer sends a FIN/RST, but Wi-Fi dropping out, doze/NAT killing the path, or the Mac
     *  sleeping without a clean disconnect can leave the socket sitting open from this
     *  side's perspective with nothing ever arriving to unblock that read — `connectionState`
     *  would then say CONNECTED indefinitely while the link is actually dead, and nothing
     *  would ever trigger the auto-reconnect loop. This sends `presence.heartbeat`
     *  periodically (proving outbound liveness) and independently tracks [lastReceivedAt]
     *  (proving inbound liveness, from *any* received frame, not just heartbeat replies);
     *  if either send fails or too long passes without receiving anything, force-closes the
     *  socket, which unblocks the blocking read in [launchConnectionLoop] with an
     *  `IOException` and lets its existing cleanup/disconnect path run normally. */
    private suspend fun heartbeatLoop(client: Socket, remoteId: String) {
        while (true) {
            delay(HEARTBEAT_INTERVAL_MS)
            val sendResult = runCatching { send(presenceEnvelope(MessageType.PRESENCE_HEARTBEAT, remoteId)) }
            val stale = System.currentTimeMillis() - lastReceivedAt > HEARTBEAT_TIMEOUT_MS
            if (sendResult.isFailure || stale) {
                Log.w(TAG, "Heartbeat failed or peer went stale (sendFailed=${sendResult.isFailure}, stale=$stale); closing connection")
                runCatching { client.close() }
                return
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
        runCatching { send(presenceEnvelope(type, recipientId)) }
    }

    private fun presenceEnvelope(type: String, recipientId: String) = Envelope(
        type = type,
        senderId = identityKeyStore.deviceId,
        recipientId = recipientId,
        payload = JsonObject(emptyMap())
    )

    companion object {
        const val DEFAULT_PORT = 7913
        private const val MAX_FRAME_BYTES = 16 * 1024 * 1024
        private const val LISTEN_BIND_ATTEMPTS = 5
        private const val LISTEN_BIND_RETRY_DELAY_MS = 500L
        private const val HEARTBEAT_INTERVAL_MS = 20_000L
        private const val HEARTBEAT_TIMEOUT_MS = 3 * HEARTBEAT_INTERVAL_MS

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
