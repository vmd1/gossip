package dev.vmd1.gossip.transport

import android.content.Context
import android.os.Build
import android.util.Base64
import android.util.Log
import dev.vmd1.gossip.crypto.IdentityKeyStore
import dev.vmd1.gossip.crypto.NoiseRole
import dev.vmd1.gossip.crypto.NoiseSession
import dev.vmd1.gossip.crypto.TrustedDevice
import dev.vmd1.gossip.crypto.TrustedDevicesStore
import dev.vmd1.gossip.protocol.DeviceType
import dev.vmd1.gossip.protocol.Envelope
import dev.vmd1.gossip.protocol.HandshakePayload
import dev.vmd1.gossip.protocol.MessageType
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
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

private const val TAG = "TransportManager"

enum class ConnectionState { DISCONNECTED, DISCOVERING, HANDSHAKING, CONNECTED }

/** Everything learned about a peer from its `handshake.hello`/`handshake.ack` envelope —
 *  mirrors Mac's `HandshakePeerInfo`. [signingPublicKey] is the peer's raw Ed25519
 *  signing public key. */
data class HandshakePeerInfo(
    val deviceId: String,
    val deviceName: String,
    val deviceType: DeviceType,
    val signingPublicKey: ByteArray
)

/**
 * Owns the connection lifecycle to every trusted peer device simultaneously (a mesh, not
 * a single pair): drives [NsdDiscovery] to advertise, accepts any number of concurrent
 * inbound [Socket]s, performs the Noise_IK handshake via [NoiseSession] on each before
 * ever tracking it as connected, and frames/deframes envelopes per the wire protocol —
 * `[4-byte big-endian length][payload]`.
 *
 * Also makes the deliver-vs-forward decision for every received envelope (see
 * [handleReceivedEnvelope]), which is what makes multi-hop relay and roster-gossip
 * broadcast actually reach devices this device has no direct connection to.
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
    private val deviceName: String = Build.MODEL ?: "Android device",
    private val deviceType: DeviceType = DeviceType.ANDROID_PHONE,
    /** Per-device feature toggles: sends for a feature turned off on this device are silently skipped. */
    private val isMessageAllowed: (type: String) -> Boolean = { true }
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** Fired when a handshake completes with a peer that is not yet in
     *  [TrustedDevicesStore] — mirrors Mac's `onUntrustedHandshake`. The pairing UI
     *  (whichever screen is currently showing a QR / listening for a first connection)
     *  should prompt the user to confirm before this returns `true`; returning `false`
     *  (or leaving this unset) tears the connection down without ever trusting it. Only
     *  one screen should be armed to answer this at a time. */
    var onUntrustedHandshake: (suspend (peer: HandshakePeerInfo, publicKey: ByteArray) -> Boolean)? = null

    /** Fired once a peer newly added to [TrustedDevicesStore] during this handshake (a
     *  brand-new pairing, not a reconnect) finishes connecting — mirrors Mac's
     *  `onNewDevicePaired`. [dev.vmd1.gossip.features.trust.RosterGossipManager] uses this to
     *  broadcast the updated roster to the rest of the mesh, the same way it already does
     *  for a pairing completed via [dev.vmd1.gossip.pairing.PairingViewModel]'s initiator-side
     *  flow (QR-scan) — this covers the responder-side flow (QR-display) instead. */
    var onNewDevicePaired: ((HandshakePeerInfo) -> Unit)? = null

    private val _connectionState = MutableStateFlow(ConnectionState.DISCONNECTED)
    val connectionState: StateFlow<ConnectionState> = _connectionState.asStateFlow()

    /** Every currently directly-connected peer's device ID — the real multi-peer signal.
     *  [connectionState] is kept as a single-value aggregate ("connected to anything or
     *  not") for source compatibility with existing consumers. */
    private val _connectedDeviceIds = MutableStateFlow<Set<String>>(emptySet())
    val connectedDeviceIds: StateFlow<Set<String>> = _connectedDeviceIds.asStateFlow()

    /** When each device (other than us) was last heard from, by any message — directly or relayed. */
    private val lastHeard = java.util.concurrent.ConcurrentHashMap<String, Long>()
    private val _meshReachableDeviceIds = MutableStateFlow<Set<String>>(emptySet())

    /** Devices we have no direct connection to but that were heard from recently via the mesh
     *  ([DeviceConnectivity.MESH_TTL_MS]). Expiry is re-evaluated every 15s and on connection changes. */
    val meshReachableDeviceIds: StateFlow<Set<String>> = _meshReachableDeviceIds.asStateFlow()

    private fun refreshMeshReachable() {
        _meshReachableDeviceIds.value = DeviceConnectivity.meshReachable(
            lastHeard = lastHeard, directIds = _connectedDeviceIds.value,
            selfId = identityKeyStore.deviceId, now = System.currentTimeMillis()
        )
    }

    private val meshExpiryJob = scope.launch {
        while (true) {
            kotlinx.coroutines.delay(15_000)
            refreshMeshReachable()
        }
    }

    /** Device ID of whichever peer most recently finished connecting. Backs
     *  [currentRemoteDeviceId] — a "primary peer" convenience for callers (pairing flow,
     *  notification/media targeting) that haven't yet been generalized to pick a specific
     *  device out of a real multi-peer set. */
    private val _lastConnectedDeviceId = MutableStateFlow<String?>(null)

    private val _incoming = MutableSharedFlow<Envelope>(extraBufferCapacity = 64)
    val incoming: SharedFlow<Envelope> = _incoming.asSharedFlow()

    /** Fired alongside [incoming]/[MessageRouter] delivery, but only for an envelope
     *  whose `hasRawFollowup` is `true`, once its raw binary frame has arrived — pairs
     *  the metadata [Envelope] with the raw bytes so a feature manager (e.g.
     *  [dev.vmd1.gossip.features.clipboard.ClipboardSyncManager] for image sync) can
     *  consume both together. See `docs/wire-protocol.md`'s "Large binary payloads"
     *  section. Single-subscriber, like [onUntrustedHandshake]/[onNewDevicePaired]. */
    var onRawFrameReceived: ((Envelope, ByteArray) -> Unit)? = null

    /** One-shot handlers for the raw binary frame expected to follow a metadata
     *  envelope from a specific peer, keyed by that peer's `deviceId`. Every envelope
     *  with `hasRawFollowup = true` arms exactly one entry here — even a duplicate
     *  being dropped, or one neither addressed to us nor being forwarded — since the
     *  raw frame is physically coming next on this connection regardless, and must be
     *  consumed to keep the frame boundary in sync even when discarded. */
    private val pendingRawFrameHandlers = ConcurrentHashMap<String, suspend (ByteArray) -> Unit>()

    val discovery = NsdDiscovery(context, identityKeyStore.deviceId, identityKeyStore.publicKeyFingerprint())

    /** A single live connection to one peer, tracked once its handshake resolves the
     *  remote `deviceId`. */
    private class PeerConnection(
        val deviceId: String,
        val socket: Socket,
        val output: DataOutputStream,
        val noiseSession: NoiseSession
    ) {
        /** Updated on every successfully-decrypted frame (any type, not just heartbeats)
         *  — see [heartbeatLoop]'s doc for why this exists. */
        @Volatile var lastReceivedAt: Long = System.currentTimeMillis()

        /** Serializes every `encrypt` + write pair for *this* peer's Noise session.
         *  `CipherState`'s nonce counter is a plain, unsynchronized `var` — concurrent
         *  encrypts on the same session race the nonce, and the receiver's AEAD nonce
         *  only advances on a successful decrypt, so one corrupted frame permanently
         *  desyncs the cipher for the rest of the connection. Per-peer, not global, now
         *  that there can be more than one session. */
        val sendMutex = Mutex()
    }

    /** Established connections, keyed by the remote device's stable UUID. */
    private val peers = ConcurrentHashMap<String, PeerConnection>()

    /** Device IDs currently being dialed (outbound only) or mid-handshake (either role),
     *  so the fallback-dial loop doesn't pile up overlapping attempts at the same peer. */
    private val dialingDeviceIds = ConcurrentHashMap.newKeySet<String>()
    private val inFlightHandshakes = AtomicInteger(0)

    private var serverSocket: ServerSocket? = null

    /** Tracks the continuous NSD discovery collection started by [listen], so
     *  [stopListening] can cancel it. See [handleDiscoveryEvent]. */
    private var discoveryJob: Job? = null

    /** Bounded, size-capped cache of recently-seen envelope IDs, used to avoid
     *  re-forwarding/re-delivering the same broadcast or relayed message twice when the
     *  mesh has more than one path between two devices. */
    private val dedupeLock = Any()
    private val recentEnvelopeIds = ArrayDeque<String>()
    private val recentEnvelopeIdSet = HashSet<String>()

    /** Listens for incoming connections (e.g. a previously-paired Mac reconnecting) and
     *  advertises this device over NSD so a Mac running discovery can find it. Accepts and
     *  tracks any number of concurrent inbound connections, not just one.
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
        discoveryJob = scope.launch {
            discovery.discover().collect { event -> handleDiscoveryEvent(event) }
        }
        scope.launch {
            val server = bindServerSocket(port) ?: return@launch
            serverSocket = server
            discovery.startAdvertising(deviceName, server.localPort)
            recomputeConnectionState()
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
        discoveryJob?.cancel()
        discoveryJob = null
        discovery.stopAdvertising()
        runCatching { serverSocket?.close() }
        serverSocket = null
        recomputeConnectionState()
    }

    /** Auto-dials any discovered peer that's already trusted and not already
     *  connected/connecting — the Android counterpart to Mac's
     *  `TransportManager.handleDiscoveredPeers`. Before this, Android only ever
     *  discovered peers during the one-time pairing flow ([PairingViewModel]); two
     *  Android devices that had already paired had no path back to each other once
     *  their original socket closed (app restart, Wi-Fi drop, etc.) short of a
     *  manually-configured [TrustedDevice.fallbackHost] — only Mac↔Android worked
     *  automatically, since Mac continuously browses Bonjour. This makes on-LAN
     *  rediscovery symmetric for Android↔Android too. [DiscoveryEvent.Lost] needs no
     *  handling here: a dead connection is detected independently by
     *  [heartbeatLoop]/a closed socket, not by NSD losing the peer's advertisement. */
    private fun handleDiscoveryEvent(event: DiscoveryEvent) {
        if (event !is DiscoveryEvent.Found) return
        val peer = event.peer
        val deviceId = peer.deviceId ?: return
        val host = peer.host ?: return
        if (!trustedDevicesStore.isTrusted(deviceId)) return
        if (peers.containsKey(deviceId) || dialingDeviceIds.contains(deviceId)) return
        val trusted = trustedDevicesStore.getDevice(deviceId) ?: return
        connect(host = host, port = peer.port, remoteStaticPublicKey = trusted.publicKey, deviceId = deviceId)
    }

    /**
     * Initiates an outbound connection to a peer at [host]:[port] using
     * [remoteStaticPublicKey] — known out-of-band from the pairing QR code or
     * `TrustedDevice` — to run the Noise_IK handshake as the initiator. [deviceId] is the
     * peer's already-known device UUID (from the QR payload or trusted-device row); used
     * to skip redundant dials when already connected/connecting to this exact peer,
     * without blocking dials to any *other* trusted device.
     */
    fun connect(host: String, port: Int, remoteStaticPublicKey: ByteArray, deviceId: String) {
        if (peers.containsKey(deviceId) || !dialingDeviceIds.add(deviceId)) return
        recomputeConnectionState()
        scope.launch {
            val client = try {
                // The (host, port) convenience constructor has no connect timeout of its
                // own — on some networks/hosts the platform default can be very long
                // (tens of seconds to minutes) for a genuinely unreachable address, during
                // which `dialingDeviceIds` blocks any retry to this same peer. An explicit
                // bounded timeout here is what actually makes that guard self-heal.
                Socket().apply { connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MS) }
            } catch (e: IOException) {
                Log.w(TAG, "Connect to $host:$port failed", e)
                dialingDeviceIds.remove(deviceId)
                recomputeConnectionState()
                return@launch
            }
            launchConnectionLoop(client, role = NoiseRole.INITIATOR, remoteStaticPublicKey = remoteStaticPublicKey, dialTargetDeviceId = deviceId)
        }
    }

    /** Encrypts and frames [envelope], resolving which currently-connected peer(s) to send
     *  it to from `envelope.broadcast`/`recipientId` — broadcast goes to every connected
     *  peer, a `recipientId` we're directly connected to goes there, and a `recipientId` we
     *  aren't directly connected to floods to every peer so it can find a multi-hop path
     *  (see [forwardTargets] and `docs/wire-protocol.md`'s "Multi-hop relay" section — this
     *  *is* that mechanism's entry point for a freshly-originated, not-yet-relayed
     *  envelope). Records the envelope's own `id` as seen so a self-addressed loop (e.g. a
     *  broadcast that somehow finds its way back around the mesh) is dropped rather than
     *  re-delivered back to whoever just sent it. */
    suspend fun send(envelope: Envelope) = withContext(Dispatchers.IO) {
        if (!isMessageAllowed(envelope.type)) return@withContext
        recordSeen(envelope.id)
        val targets = forwardTargets(envelope, arrivedFrom = null)
        if (targets.isEmpty()) throw IllegalStateException("Not connected")
        var lastError: Throwable? = null
        for (target in targets) {
            try {
                sendTo(envelope, target)
            } catch (e: Exception) {
                lastError = e
            }
        }
        lastError?.let { throw it }
    }

    /** Encrypts + writes [envelope] to one specific peer. Both the encrypt and the write
     *  must happen inside [PeerConnection.sendMutex] — see its doc for why. */
    private suspend fun sendTo(envelope: Envelope, peer: PeerConnection) {
        peer.sendMutex.withLock {
            val ciphertext = peer.noiseSession.encryptTransportMessage(envelope.encode())
            writeFrame(peer.output, ciphertext)
        }
    }

    /** Originates a `hasRawFollowup` envelope + its raw binary frame — the counterpart
     *  to [send] for a locally-originated (not relayed) send carrying a large binary
     *  payload (e.g. clipboard image sync). Resolves targets from
     *  `envelope.broadcast`/`recipientId` exactly like [send]; devices with no direct
     *  connection to any of those targets receive it via each target's own relay (see
     *  [handleReceivedEnvelope]), not directly from here. */
    suspend fun send(envelope: Envelope, rawFollowup: ByteArray) = withContext(Dispatchers.IO) {
        if (!isMessageAllowed(envelope.type)) return@withContext
        recordSeen(envelope.id)
        val targets = forwardTargets(envelope, arrivedFrom = null)
        if (targets.isEmpty()) throw IllegalStateException("Not connected")
        var lastError: Throwable? = null
        for (target in targets) {
            try {
                sendWithRawFollowup(envelope, rawFollowup, target)
            } catch (e: Exception) {
                lastError = e
            }
        }
        lastError?.let { throw it }
    }

    /** Encrypts + writes [envelope] to one specific peer, immediately followed by a
     *  second raw (non-envelope) Noise-encrypted frame carrying [rawData] — the "large
     *  binary payload" convention in `docs/wire-protocol.md`. Both frames are written
     *  atomically inside [PeerConnection.sendMutex] so nothing else (e.g. a concurrent
     *  DND update) can interleave a third frame between them, which would break that
     *  peer's "the very next frame is the raw payload" expectation — this holds at
     *  every hop, which is what makes relaying a raw-followup envelope safe (see
     *  [handleReceivedEnvelope]). */
    private suspend fun sendWithRawFollowup(envelope: Envelope, rawData: ByteArray, peer: PeerConnection) {
        peer.sendMutex.withLock {
            val ciphertext = peer.noiseSession.encryptTransportMessage(envelope.encode())
            writeFrame(peer.output, ciphertext)
            val rawCiphertext = peer.noiseSession.encryptTransportMessage(rawData)
            writeFrame(peer.output, rawCiphertext)
        }
    }

    /** Device ID of whichever peer most recently finished connecting, if it's still
     *  connected. A "primary peer" convenience — see [_lastConnectedDeviceId]'s doc. */
    fun currentRemoteDeviceId(): String? = _lastConnectedDeviceId.value?.takeIf { peers.containsKey(it) }

    /** Tears down every currently-connected peer. */
    fun disconnect() {
        for (peer in peers.values.toList()) {
            teardown(peer)
        }
        recomputeConnectionState()
    }

    /** Tears down the live connection to one specific peer, if any (e.g. after
     *  `trust.revoke`) — leaves every other peer untouched. */
    fun disconnect(deviceId: String) {
        peers[deviceId]?.let { teardown(it) }
        recomputeConnectionState()
    }

    fun shutdown() {
        disconnect()
        stopListening()
        scope.cancel()
    }

    private fun launchConnectionLoop(
        client: Socket,
        role: NoiseRole,
        remoteStaticPublicKey: ByteArray?,
        dialTargetDeviceId: String? = null
    ) {
        inFlightHandshakes.incrementAndGet()
        recomputeConnectionState()
        var handshakeSettled = false
        fun settleDialing() {
            if (handshakeSettled) return
            handshakeSettled = true
            dialTargetDeviceId?.let { dialingDeviceIds.remove(it) }
            inFlightHandshakes.decrementAndGet()
        }

        scope.launch {
            var peer: PeerConnection? = null
            try {
                // Bounds the blocking handshake reads below to HANDSHAKE_TIMEOUT_MS: a
                // peer that accepts the TCP connection but never completes Noise (app
                // killed mid-handshake, aggressive Doze, etc.) would otherwise block this
                // coroutine — and hold `dialingDeviceIds`/`inFlightHandshakes` — forever,
                // observed directly as this device looking permanently "stuck" reconnecting
                // (the fallback-dial loop's own guard sees a dial as still in progress and
                // never retries). Cleared back to infinite once the handshake completes —
                // steady-state idle periods between messages are expected and covered by
                // `heartbeatLoop`'s own liveness check instead, not a socket-level timeout.
                client.soTimeout = HANDSHAKE_TIMEOUT_MS.toInt()
                val input = DataInputStream(client.getInputStream())
                val out = DataOutputStream(client.getOutputStream())

                val session = NoiseSession(role, identityKeyStore.x25519KeyPair, remoteStaticPublicKey)
                val peerInfo = if (role == NoiseRole.INITIATOR) {
                    performInitiatorHandshake(session, out, input)
                } else {
                    performResponderHandshake(session, out, input)
                }
                client.soTimeout = 0
                val remoteId = peerInfo.deviceId
                settleDialing()
                recomputeConnectionState()

                // Only the RESPONDER role is trust-gated here. The initiator role only
                // ever dials a deviceId the caller already vetted (an existing trusted
                // row, or a freshly-scanned QR's public key the user just consented to by
                // scanning it) — that caller (PairingViewModel) adds it to
                // TrustedDevicesStore itself once connected, same as before mesh support.
                // The responder role, by contrast, accepts inbound from *anyone* who can
                // complete a Noise handshake — this is the gate that makes "show a QR to
                // pair" safe, mirroring Mac's `onUntrustedHandshake` (previously Android
                // had no equivalent at all, since nothing untrusted ever dialed in before
                // mesh support and QR-display existed).
                if (role == NoiseRole.RESPONDER && !trustedDevicesStore.isTrusted(remoteId)) {
                    val remotePublicKey = session.remoteStaticKey
                    if (remotePublicKey == null) {
                        Log.w(TAG, "Handshake with $remoteId completed without a resolved remote static key")
                        runCatching { client.close() }
                        return@launch
                    }
                    val confirmed = onUntrustedHandshake?.invoke(peerInfo, remotePublicKey) ?: false
                    if (!confirmed) {
                        Log.i(TAG, "Untrusted handshake with $remoteId not confirmed; closing")
                        runCatching { client.close() }
                        return@launch
                    }
                    trustedDevicesStore.addDevice(
                        TrustedDevice(
                            deviceId = peerInfo.deviceId,
                            publicKey = remotePublicKey,
                            deviceName = peerInfo.deviceName,
                            deviceType = peerInfo.deviceType,
                            addedAt = System.currentTimeMillis(),
                            signingPublicKey = peerInfo.signingPublicKey
                        )
                    )
                    onNewDevicePaired?.invoke(peerInfo)
                }

                val newPeer = PeerConnection(remoteId, client, out, session)
                peer = newPeer
                peers[remoteId]?.let { stale -> teardown(stale) }
                peers[remoteId] = newPeer
                _lastConnectedDeviceId.value = remoteId
                recomputeConnectionState()
                Log.i(TAG, "Connected ($role) to device $remoteId")

                sendPresence(MessageType.PRESENCE_ONLINE, remoteId)
                val heartbeatJob = scope.launch { heartbeatLoop(newPeer) }

                try {
                    while (true) {
                        val frame = readFrame(input)
                        val plaintext = session.decryptTransportMessage(frame)
                        newPeer.lastReceivedAt = System.currentTimeMillis()
                        // A raw (non-envelope) frame armed while handling the metadata
                        // envelope that announced it (`hasRawFollowup = true`) — see
                        // `handleReceivedEnvelope` and `docs/wire-protocol.md`'s "Large
                        // binary payloads" section. Must be checked before attempting
                        // `Envelope.decode`, since a raw frame isn't JSON at all.
                        val rawHandler = pendingRawFrameHandlers.remove(remoteId)
                        if (rawHandler != null) {
                            rawHandler(plaintext)
                            continue
                        }
                        val envelope = Envelope.decode(plaintext)
                        handleReceivedEnvelope(envelope, arrivedFrom = remoteId)
                    }
                } finally {
                    heartbeatJob.cancel()
                }
            } catch (e: Exception) {
                Log.w(TAG, "Connection loop ended: ${e.message}")
            } finally {
                settleDialing()
                runCatching { client.close() }
                val currentPeer = peer
                if (currentPeer != null && peers[currentPeer.deviceId] === currentPeer) {
                    peers.remove(currentPeer.deviceId)
                }
                recomputeConnectionState()
            }
        }
    }

    /** Detects a *silently* dropped connection to one specific peer — the case a clean TCP
     *  close doesn't cover. The receive loop's `readFrame` blocks on the socket and throws
     *  promptly when the peer sends a FIN/RST, but Wi-Fi dropping out, doze/NAT killing the
     *  path, or the peer sleeping without a clean disconnect can leave the socket sitting
     *  open from this side's perspective with nothing ever arriving to unblock that read
     *  for *this peer* — nothing would ever trigger reconnection to just that one. Sends a
     *  targeted `presence.heartbeat` to this peer periodically (proving outbound liveness)
     *  and checks this peer's own `lastReceivedAt` (proving inbound liveness, from *any*
     *  received frame, not just heartbeat replies); if either fails, force-closes only this
     *  peer's socket, which unblocks its own receive loop with an `IOException` and lets
     *  its existing cleanup path run normally. */
    private suspend fun heartbeatLoop(peer: PeerConnection) {
        while (true) {
            delay(HEARTBEAT_INTERVAL_MS)
            val sendResult = runCatching { sendTo(presenceEnvelope(MessageType.PRESENCE_HEARTBEAT, peer.deviceId), peer) }
            val stale = System.currentTimeMillis() - peer.lastReceivedAt > HEARTBEAT_TIMEOUT_MS
            if (sendResult.isFailure || stale) {
                Log.w(TAG, "Heartbeat failed or peer ${peer.deviceId} went stale (sendFailed=${sendResult.isFailure}, stale=$stale); closing connection")
                runCatching { peer.socket.close() }
                return
            }
        }
    }

    /** The core mesh routing decision, run on every successfully decoded inbound envelope:
     *  deliver locally if it's addressed to us (directly or via broadcast), and/or forward
     *  it on toward wherever else it needs to go. See `docs/wire-protocol.md`'s "Multi-hop
     *  relay" section for the canonical algorithm both platforms implement.
     *
     *  Forwarding is never a raw-ciphertext relay: each hop's Noise session is pairwise, so
     *  a frame decrypted under the sender's session here is re-encrypted from scratch under
     *  each forward target's own session by [sendTo].
     *
     *  A `hasRawFollowup` envelope is handled differently: delivery and forwarding are both
     *  *deferred* until the raw frame that follows this envelope actually arrives (armed via
     *  [pendingRawFrameHandlers]), so that a relayed hop always forwards the metadata
     *  envelope and its raw frame atomically as a pair — never the metadata alone, which
     *  would desync a downstream hop's own "next frame is raw" expectation if some other
     *  message interleaved in between. */
    private suspend fun handleReceivedEnvelope(envelope: Envelope, arrivedFrom: String) {
        // Any message from a device — even one relayed through another — proves it is reachable.
        if (envelope.senderId != identityKeyStore.deviceId) {
            val first = lastHeard.put(envelope.senderId, System.currentTimeMillis()) == null
            if (first || envelope.senderId !in _meshReachableDeviceIds.value) refreshMeshReachable()
        }
        if (!recordSeen(envelope.id)) {
            // Already processed/forwarded this one — but if it carries a raw follow-up,
            // that frame is still physically coming next on this connection and must be
            // drained, just discarded rather than acted on.
            if (envelope.hasRawFollowup) {
                pendingRawFrameHandlers[arrivedFrom] = {}
            }
            return
        }

        val isForMe = envelope.recipientId == identityKeyStore.deviceId || envelope.broadcast
        val targets = if (envelope.ttl > 0) forwardTargets(envelope, arrivedFrom) else emptyList()

        if (envelope.hasRawFollowup) {
            pendingRawFrameHandlers[arrivedFrom] = handler@{ data ->
                if (isForMe) {
                    _incoming.emit(envelope)
                    messageRouter.dispatch(envelope)
                    onRawFrameReceived?.invoke(envelope, data)
                }
                if (targets.isEmpty()) return@handler
                val forwarded = envelope.copy(ttl = envelope.ttl - 1)
                for (target in targets) {
                    runCatching { sendWithRawFollowup(forwarded, data, target) }
                }
            }
            return
        }

        if (isForMe) {
            _incoming.emit(envelope)
            messageRouter.dispatch(envelope)
        }
        if (targets.isEmpty()) return
        val forwarded = envelope.copy(ttl = envelope.ttl - 1)
        for (target in targets) {
            runCatching { sendTo(forwarded, target) }
        }
    }

    /** Resolves which currently-connected peers an envelope should be sent/forwarded to.
     *  [arrivedFrom] is the peer this envelope was just relayed from (excluded from
     *  re-forwarding back to); pass `null` for a locally-originated send. */
    private fun forwardTargets(envelope: Envelope, arrivedFrom: String?): List<PeerConnection> {
        if (envelope.broadcast) {
            return peers.values.filter { it.deviceId != arrivedFrom }
        }
        val recipientId = envelope.recipientId
        if (recipientId == null || recipientId == identityKeyStore.deviceId) {
            return emptyList()
        }
        peers[recipientId]?.let { return listOf(it) }
        // Not directly connected to the recipient — flood so it can find a multi-hop
        // path through whatever else we're connected to.
        return peers.values.filter { it.deviceId != arrivedFrom }
    }

    /** Inserts [id] into the recently-seen cache. Returns `true` if this is the first time
     *  we've seen it (caller should process/deliver it), `false` if it's a duplicate
     *  (caller should drop it). Bounded to [DEDUPE_CACHE_LIMIT] entries, oldest evicted
     *  first — generous relative to a small mesh's expected chat volume (clipboard/DND/
     *  media/roster-gossip), not a full time-windowed LRU since that precision isn't
     *  needed here. */
    private fun recordSeen(id: String): Boolean = synchronized(dedupeLock) {
        if (!recentEnvelopeIdSet.add(id)) return@synchronized false
        recentEnvelopeIds.addLast(id)
        if (recentEnvelopeIds.size > DEDUPE_CACHE_LIMIT) {
            val evicted = recentEnvelopeIds.removeFirst()
            recentEnvelopeIdSet.remove(evicted)
        }
        true
    }

    private fun teardown(peer: PeerConnection) {
        runCatching { peer.socket.close() }
        if (peers[peer.deviceId] === peer) {
            peers.remove(peer.deviceId)
        }
    }

    private fun recomputeConnectionState() {
        val ids = peers.keys.toSet()
        _connectedDeviceIds.value = ids
        refreshMeshReachable()
        _connectionState.value = when {
            ids.isNotEmpty() -> ConnectionState.CONNECTED
            inFlightHandshakes.get() > 0 -> ConnectionState.HANDSHAKING
            serverSocket?.isClosed == false || dialingDeviceIds.isNotEmpty() -> ConnectionState.DISCOVERING
            else -> ConnectionState.DISCONNECTED
        }
    }

    private fun performInitiatorHandshake(session: NoiseSession, out: DataOutputStream, input: DataInputStream): HandshakePeerInfo {
        val message1 = session.writeMessage1(ByteArray(0))
        val helloEnvelope = Envelope(
            type = MessageType.HANDSHAKE_HELLO,
            senderId = identityKeyStore.deviceId,
            payload = HandshakePayload(
                noise = Base64.encodeToString(message1, Base64.NO_WRAP),
                deviceName = deviceName,
                deviceType = deviceType.wireValue,
                signingPublicKey = Base64.encodeToString(identityKeyStore.ed25519PublicKey, Base64.NO_WRAP)
            ).toJsonObject()
        )
        writeFrame(out, helloEnvelope.encode())

        val ackBytes = readFrame(input)
        val ackEnvelope = Envelope.decode(ackBytes)
        require(ackEnvelope.type == MessageType.HANDSHAKE_ACK) { "Expected handshake.ack, got ${ackEnvelope.type}" }
        val ackPayload = HandshakePayload.fromJsonObject(ackEnvelope.payload)
        val message2 = Base64.decode(ackPayload.noise, Base64.NO_WRAP)
        session.readMessage2(message2)
        return HandshakePeerInfo(
            deviceId = ackEnvelope.senderId,
            deviceName = ackPayload.deviceName,
            deviceType = DeviceType.fromWire(ackPayload.deviceType),
            signingPublicKey = Base64.decode(ackPayload.signingPublicKey, Base64.NO_WRAP)
        )
    }

    private fun performResponderHandshake(session: NoiseSession, out: DataOutputStream, input: DataInputStream): HandshakePeerInfo {
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
                deviceType = deviceType.wireValue,
                signingPublicKey = Base64.encodeToString(identityKeyStore.ed25519PublicKey, Base64.NO_WRAP)
            ).toJsonObject()
        )
        writeFrame(out, ackEnvelope.encode())
        return HandshakePeerInfo(
            deviceId = helloEnvelope.senderId,
            deviceName = helloPayload.deviceName,
            deviceType = DeviceType.fromWire(helloPayload.deviceType),
            signingPublicKey = Base64.decode(helloPayload.signingPublicKey, Base64.NO_WRAP)
        )
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
        private const val CONNECT_TIMEOUT_MS = 10_000
        private const val HANDSHAKE_TIMEOUT_MS = 15_000L
        private const val DEDUPE_CACHE_LIMIT = 512

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
