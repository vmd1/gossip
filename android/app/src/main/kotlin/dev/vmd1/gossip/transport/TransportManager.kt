package dev.vmd1.gossip.transport

import android.content.Context
import android.os.Build
import dev.vmd1.gossip.crypto.IdentityKeyStore
import dev.vmd1.gossip.crypto.TrustedDevicesStore
import dev.vmd1.gossip.protocol.DeviceType
import dev.vmd1.gossip.protocol.Envelope
import dev.vmd1.gossip.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.IOException
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

private const val TAG = "TransportManager"

enum class ConnectionState { DISCONNECTED, DISCOVERING, HANDSHAKING, CONNECTED }

/** Everything learned about a peer from its authenticated handshake — mirrors Mac's `HandshakePeerInfo`.
 *  [signingPublicKey] is the peer's raw Ed25519 signing public key. */
data class HandshakePeerInfo(
    val deviceId: String,
    val deviceName: String,
    val deviceType: DeviceType,
    val signingPublicKey: ByteArray,
    /** Token the initiator presented inside its Noise payload (responder role only). */
    val pairingToken: String? = null
)

/**
 * Owns the sockets to every trusted peer device simultaneously (a mesh, not a single pair).
 *
 * The protocol itself lives in the Rust engine (`desktop/core`, reached only through [CoreBridge]): the Noise_IK
 * handshake and transport, framing, envelope signing/verification, de-duplication, the deliver-vs-forward decision that
 * makes multi-hop relay work, trust gating of unknown devices, heartbeats and reconciliation timing. This class is the
 * shell around it: it drives [NsdDiscovery], accepts and dials [Socket]s, feeds the engine the bytes that arrive,
 * writes the bytes it returns, and turns its events into the flows and callbacks the rest of the app uses.
 *
 * Ordering matters: the engine's Noise nonces are implicit counters, so the order in which its output reaches a socket
 * must be the order it was produced in. Every engine call therefore happens under [engineLock], which also enqueues
 * the resulting writes (each connection has its own writer, so a slow peer never holds the lock). Events for the rest
 * of the app are queued under the same lock and delivered, in order, by one dispatcher.
 */
class TransportManager(
    private val context: Context,
    val identityKeyStore: IdentityKeyStore,
    private val trustedDevicesStore: TrustedDevicesStore,
    val messageRouter: MessageRouter,
    private val deviceName: String = Build.MODEL ?: "Android device",
    private val deviceType: DeviceType = DeviceType.ANDROID_PHONE,
    /** Per-device feature toggles: sends for a feature turned off on this device are silently skipped. */
    private val isMessageAllowed: (type: String) -> Boolean = { true },
    /** Keys of the features turned off on this device, for the engine's own gate (see [setDisabledFeatures]). */
    initialDisabledFeatures: List<String> = emptyList()
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
    private val lastHeard = ConcurrentHashMap<String, Long>()
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
            delay(15_000)
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

    val discovery = NsdDiscovery(context, identityKeyStore.deviceId, identityKeyStore.publicKeyFingerprint())

    // ---- The engine ---------------------------------------------------------------------------------------------

    /** Created on first use, so merely constructing a [TransportManager] (some tests do) loads no native code. */
    private val bridge: CoreBridge by lazy {
        CoreBridge(
            deviceId = identityKeyStore.deviceId,
            noiseSecret = identityKeyStore.x25519KeyPair.privateKey,
            signingSeed = identityKeyStore.ed25519PrivateKey,
            deviceName = deviceName,
            deviceType = deviceType,
            trustedDevices = trustedDevicesStore,
            disabledFeatures = currentDisabledFeatures
        )
    }
    @Volatile private var currentDisabledFeatures: List<String> = initialDisabledFeatures

    /** Guards the engine and the ordering of everything it produces. Never held across a blocking socket operation. */
    private val engineLock = ReentrantLock()

    /** Events for the rest of the app, queued under [engineLock] and delivered in that order by one dispatcher. */
    private val events = Channel<CoreBridge.BridgeAction>(Channel.UNLIMITED)

    @OptIn(ExperimentalCoroutinesApi::class)
    private val dispatcher = scope.launch(Dispatchers.IO.limitedParallelism(1)) {
        for (event in events) {
            runCatching { dispatch(event) }.onFailure { Log.w(TAG, "Event handler failed: ${it.message}") }
        }
    }

    /** The app edited its own trust table (the pairing flow adds a provisional row before dialing): tell the engine. */
    private val trustChanged = Channel<Unit>(Channel.CONFLATED)

    init {
        trustedDevicesStore.addChangeListener { trustChanged.trySend(Unit) }
        scope.launch {
            for (ignored in trustChanged) {
                runCatching { engineLock.withLock { bridge.syncTrustFromStore() } }
                    .onFailure { Log.w(TAG, "Could not sync trust into the engine: ${it.message}") }
            }
        }
        // The engine's clock: heartbeats, stale and stuck-handshake cleanup, pairing expiry, reconciliation.
        scope.launch {
            while (isActive) {
                delay(TICK_INTERVAL_MS)
                runCatching { runEngine { bridge.tick() } }.onFailure { Log.w(TAG, "Engine tick failed: ${it.message}") }
            }
        }
    }

    /** Runs one engine call and carries out what it decided; the lock is released before this returns. */
    private fun runEngine(body: () -> List<CoreBridge.BridgeAction>) {
        engineLock.withLock { carryOut(body()) }
    }

    /** Must be called with [engineLock] held. Writes and closes happen in order; events are queued for the dispatcher. */
    private fun carryOut(actions: List<CoreBridge.BridgeAction>) {
        for (action in actions) {
            when (action) {
                is CoreBridge.BridgeAction.Close -> closeLink(action.conn, notifyEngine = false)
                is CoreBridge.BridgeAction.PeerConnected -> {
                    links[action.conn]?.let { link ->
                        link.deviceId = action.peer.deviceId
                        linkByDevice[action.peer.deviceId] = action.conn
                        releaseInbound(link)
                    }
                    recomputeConnectionState()
                    events.trySend(action)
                }
                is CoreBridge.BridgeAction.PeerDisconnected -> {
                    linkByDevice[action.deviceId]?.let { conn -> if (links[conn] == null) linkByDevice.remove(action.deviceId, conn) }
                    recomputeConnectionState()
                    events.trySend(action)
                }
                // The trust table is the app's too: apply the engine's change before anything else can observe it.
                is CoreBridge.BridgeAction.TrustChanged -> trustedDevicesStore.importCoreSnapshot(action.snapshotJson)
                else -> events.trySend(action)
            }
        }
    }

    private suspend fun dispatch(event: CoreBridge.BridgeAction) {
        when (event) {
            is CoreBridge.BridgeAction.PeerConnected -> {
                _lastConnectedDeviceId.value = event.peer.deviceId
                Log.i(TAG, "Connected to device ${event.peer.deviceId}")
                if (event.newlyPaired) onNewDevicePaired?.invoke(event.peer)
            }
            is CoreBridge.BridgeAction.PeerDisconnected -> Unit
            is CoreBridge.BridgeAction.PairingPrompt -> {
                // The user answers on their own time; never block the dispatcher (or the lock) while they decide.
                promptJobs[event.conn] = scope.launch {
                    val confirmed = runCatching { onUntrustedHandshake?.invoke(event.peer, event.publicKey) ?: false }.getOrDefault(false)
                    promptJobs.remove(event.conn)
                    runCatching { runEngine { bridge.confirmPairing(event.conn, confirmed) } }
                }
            }
            is CoreBridge.BridgeAction.PairingPromptCancelled -> promptJobs.remove(event.conn)?.cancel()
            is CoreBridge.BridgeAction.Deliver -> {
                _incoming.emit(event.envelope)
                messageRouter.dispatch(event.envelope)
                event.raw?.let { onRawFrameReceived?.invoke(event.envelope, it) }
            }
            is CoreBridge.BridgeAction.Heard -> {
                val first = lastHeard.put(event.deviceId, System.currentTimeMillis()) == null
                if (first || event.deviceId !in _meshReachableDeviceIds.value) refreshMeshReachable()
            }
            is CoreBridge.BridgeAction.ReconcileDue -> {
                // Only trust gossip is scheduled by the engine for now; each feature still runs its own resync loop.
                if (event.task == "trust.roster_update") sendRoster(event.peer)
            }
            is CoreBridge.BridgeAction.DeviceRevoked -> Unit
            else -> Unit
        }
    }

    private val promptJobs = ConcurrentHashMap<ULong, Job>()

    // ---- Sockets --------------------------------------------------------------------------------------------------

    /** One socket. While a handshake is in flight [deviceId] is `null`; the engine tells us who it is on promotion. */
    private inner class Link(val conn: ULong, val socket: Socket, val dialTarget: String?, val inboundHost: String?) {
        @Volatile var deviceId: String? = null
        @Volatile var closed = false
        val inboundReleased = AtomicBoolean(inboundHost == null)
        private val writes = Channel<ByteArray>(Channel.UNLIMITED)
        private val queuedBytes = AtomicLong(0)
        val peerIpAddress: String? get() = socket.inetAddress?.hostAddress?.substringBefore('%')

        /** Called under [engineLock]; never blocks. A peer that stops reading is dropped rather than buffered forever. */
        fun enqueue(bytes: ByteArray) {
            if (closed) return
            if (queuedBytes.addAndGet(bytes.size.toLong()) > MAX_QUEUED_WRITE_BYTES) {
                Log.w(TAG, "Peer is not reading; dropping the connection")
                scope.launch { closeLink(conn, notifyEngine = true) }
                return
            }
            writes.trySend(bytes)
        }

        fun startWriter() = scope.launch {
            val out: OutputStream = socket.getOutputStream()
            try {
                for (bytes in writes) {
                    out.write(bytes)
                    out.flush()
                    queuedBytes.addAndGet(-bytes.size.toLong())
                }
            } catch (e: IOException) {
                if (!closed) closeLink(conn, notifyEngine = true)
            }
        }

        fun startReader() = scope.launch {
            val buffer = ByteArray(READ_BUFFER_BYTES)
            try {
                val input = socket.getInputStream()
                while (isActive && !closed) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    runEngine { bridge.bytesReceived(conn, buffer.copyOf(n)) }
                }
            } catch (e: IOException) {
                if (!closed) Log.w(TAG, "Connection read ended: ${e.message}")
            } finally {
                closeLink(conn, notifyEngine = true)
            }
        }

        fun close() {
            closed = true
            writes.close()
            runCatching { socket.close() }
        }
    }

    private val links = ConcurrentHashMap<ULong, Link>()
    private val linkByDevice = ConcurrentHashMap<String, ULong>()

    /** Devices with an outbound socket still connecting (before the engine's own dial guard applies). */
    private val connecting = ConcurrentHashMap.newKeySet<String>()
    private val nextConn = AtomicLong(1)
    private var serverSocket: ServerSocket? = null
    private var discoveryJob: Job? = null

    /** Removes a socket. [notifyEngine] is false when the engine itself asked for the close (it has already forgotten it). */
    private fun closeLink(conn: ULong, notifyEngine: Boolean) {
        val link = links.remove(conn) ?: return
        link.close()
        releaseInbound(link)
        link.dialTarget?.let { connecting.remove(it) }
        link.deviceId?.let { id -> linkByDevice.remove(id, conn) }
        if (notifyEngine) {
            // Not under the engine lock yet (this can be called from a socket thread): take it for the engine call.
            runCatching { runEngine { bridge.connectionClosed(conn) } }
        }
        recomputeConnectionState()
    }

    private fun recomputeConnectionState() {
        val ids = linkByDevice.keys.toSet()
        _connectedDeviceIds.value = ids
        refreshMeshReachable()
        _connectionState.value = when {
            ids.isNotEmpty() -> ConnectionState.CONNECTED
            links.values.any { it.deviceId == null } -> ConnectionState.HANDSHAKING
            serverSocket?.isClosed == false || connecting.isNotEmpty() -> ConnectionState.DISCOVERING
            else -> ConnectionState.DISCONNECTED
        }
    }

    /** Pre-authentication limits on inbound connections: overall and per source address. */
    private val pendingInboundByHost = ConcurrentHashMap<String, AtomicInteger>()
    private val pendingInboundTotal = AtomicInteger(0)

    /** IPv6 peers are limited per /64 (one host can own billions of addresses in its prefix); IPv4 per address. */
    private fun hostKey(client: Socket): String {
        val address = client.inetAddress ?: return "unknown"
        return if (address is java.net.Inet6Address) address.address.copyOf(8).joinToString("") { "%02x".format(it) }
        else address.hostAddress ?: "unknown"
    }

    private fun admitInbound(client: Socket): String? {
        val host = hostKey(client)
        val perHost = pendingInboundByHost.computeIfAbsent(host) { AtomicInteger(0) }
        if (pendingInboundTotal.get() >= MAX_PENDING_INBOUND || perHost.get() >= MAX_PENDING_INBOUND_PER_HOST) {
            Log.w(TAG, "Too many pending inbound connections; refusing one")
            return null
        }
        pendingInboundTotal.incrementAndGet()
        perHost.incrementAndGet()
        return host
    }

    private fun releaseInbound(link: Link) {
        val host = link.inboundHost ?: return
        if (!link.inboundReleased.compareAndSet(false, true)) return
        pendingInboundTotal.decrementAndGet()
        pendingInboundByHost[host]?.let { if (it.decrementAndGet() <= 0) pendingInboundByHost.remove(host, it) }
    }

    // ---- Listening ------------------------------------------------------------------------------------------------

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
                val host = admitInbound(client)
                if (host == null) {
                    runCatching { client.close() }
                    continue
                }
                acceptInbound(client, host)
            }
        }
    }

    private fun acceptInbound(client: Socket, host: String) {
        val link = Link(nextConn.getAndIncrement().toULong(), client, dialTarget = null, inboundHost = host)
        links[link.conn] = link
        try {
            engineLock.withLock {
                bridge.syncTrustFromStore()
                carryOut(bridge.accepted(link.conn))
            }
        } catch (e: Exception) {
            Log.w(TAG, "Could not accept a connection: ${e.message}")
            closeLink(link.conn, notifyEngine = false)
            return
        }
        recomputeConnectionState()
        link.startWriter()
        link.startReader()
    }

    /** While a pairing QR is on screen, its token. An untrusted peer is only ever offered to
     *  the user while this is armed and the peer presents it; the engine enforces single use and expiry. */
    fun armPairing(token: String) = engineLock.withLock { bridge.armPairing(token) }

    fun disarmPairing() = engineLock.withLock { bridge.disarmPairing() }

    /** The code both devices derive for this pairing; see [PairingCode]. */
    fun pairingCodeFor(remoteStaticKey: ByteArray): String =
        uniffi.gossip_ffi.pairingCode(identityKeyStore.x25519KeyPair.publicKey, remoteStaticKey)

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
     *  handling here: a dead connection is detected independently by the engine's
     *  heartbeat/a closed socket, not by NSD losing the peer's advertisement. */
    private fun handleDiscoveryEvent(event: DiscoveryEvent) {
        if (event !is DiscoveryEvent.Found) return
        val peer = event.peer
        val deviceId = peer.deviceId ?: return
        val host = peer.host ?: return
        val trusted = trustedDevicesStore.getDevice(deviceId) ?: return
        // Anyone on the LAN can advertise a trusted device's id; only dial an advertisement whose key fingerprint
        // matches the key we pinned, so a squatter can't tie up the per-device dial slot.
        if (!fingerprintMatches(peer.publicKeyFingerprint, trusted.publicKey)) return
        connect(host, port = peer.port, remoteStaticPublicKey = trusted.publicKey, deviceId = deviceId)
    }

    // ---- Dialing --------------------------------------------------------------------------------------------------

    /**
     * Initiates an outbound connection to a peer at [host]:[port] using
     * [remoteStaticPublicKey] — known out-of-band from the pairing QR code or
     * `TrustedDevice` — to run the Noise_IK handshake as the initiator. [deviceId] is the
     * peer's already-known device UUID (from the QR payload or trusted-device row); used
     * to skip redundant dials when already connected/connecting to this exact peer,
     * without blocking dials to any *other* trusted device.
     *
     * The app's trust table is handed to the engine first, so a provisional row the pairing flow has just added is
     * dialable.
     */
    fun connect(host: String, port: Int, remoteStaticPublicKey: ByteArray, deviceId: String, pairingToken: String? = null) {
        if (!connecting.add(deviceId)) return
        val engineWillDial = runCatching { engineLock.withLock { bridge.syncTrustFromStore(); bridge.shouldDial(deviceId) } }.getOrDefault(false)
        if (!engineWillDial) {
            connecting.remove(deviceId)
            return
        }
        recomputeConnectionState()
        scope.launch {
            val socket = try {
                // The (host, port) convenience constructor has no connect timeout of its own — on some networks the
                // platform default can be very long for a genuinely unreachable address, during which `connecting`
                // would block any retry to this same peer. An explicit bounded timeout is what makes that guard self-heal.
                Socket().apply { connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MS) }
            } catch (e: IOException) {
                Log.w(TAG, "Connect to $host:$port failed", e)
                connecting.remove(deviceId)
                recomputeConnectionState()
                return@launch
            }
            val link = Link(nextConn.getAndIncrement().toULong(), socket, dialTarget = deviceId, inboundHost = null)
            links[link.conn] = link
            try {
                engineLock.withLock { carryOut(bridge.dial(link.conn, deviceId, remoteStaticPublicKey, pairingToken)) }
            } catch (e: Exception) {
                Log.w(TAG, "Could not start the handshake with $deviceId: ${e.message}")
                closeLink(link.conn, notifyEngine = false)
                return@launch
            }
            connecting.remove(deviceId)
            recomputeConnectionState()
            link.startWriter()
            link.startReader()
        }
    }

    // ---- Sending --------------------------------------------------------------------------------------------------

    /** Signs (if locally originated), records and sends [unsigned] toward everyone it addresses: a broadcast goes to
     *  every connected peer, a `recipientId` we're directly connected to goes there, and one we aren't is flooded to
     *  every peer so it can find a multi-hop path. A message for a feature turned off on this device is silently
     *  skipped. Throws when there is nobody to send it to. */
    suspend fun send(unsigned: Envelope) = withContext(Dispatchers.IO) {
        if (!isMessageAllowed(unsigned.type)) return@withContext
        sendThroughEngine { bridge.send(unsigned) }
    }

    /** Originates a `hasRawFollowup` envelope + its raw binary frame (e.g. clipboard image sync); the engine binds the
     *  raw frame's hash into the signed payload. Peers with no direct connection to the target receive it via the
     *  relays, which forward the pair atomically. */
    suspend fun send(unsigned: Envelope, rawFollowup: ByteArray) = withContext(Dispatchers.IO) {
        if (!isMessageAllowed(unsigned.type)) return@withContext
        sendThroughEngine { bridge.send(unsigned, rawFollowup) }
    }

    private fun sendThroughEngine(body: () -> List<CoreBridge.BridgeAction>) {
        try {
            runEngine(body)
        } catch (e: CoreBridge.BridgeException) {
            throw if (e.kind == CoreBridge.BridgeException.Kind.NOT_CONNECTED) IllegalStateException("Not connected") else e
        }
    }

    /** Sends this device's roster to [peer], or broadcasts it to the whole mesh when [peer] is `null`. */
    fun sendRoster(peer: String?) {
        scope.launch {
            runCatching { sendThroughEngine { bridge.send(bridge.rosterUpdate(peer)) } }
                .onFailure { Log.w(TAG, "Failed to send roster: ${it.message}") }
        }
    }

    /** The user removed a device: the engine drops its trust and connection and broadcasts `trust.revoke`. */
    fun revokeDevice(deviceId: String) {
        runCatching { runEngine { bridge.revokeDevice(deviceId) } }.onFailure { Log.w(TAG, "Revoke failed: ${it.message}") }
    }

    /** Tells the engine which features are turned off on this device (keys as in `desktop/core` `features.rs`). */
    fun setDisabledFeatures(keys: List<String>) {
        currentDisabledFeatures = keys
        runCatching { engineLock.withLock { bridge.setDisabledFeatures(keys) } }
    }

    /** Device ID of whichever peer most recently finished connecting, if it's still
     *  connected. A "primary peer" convenience — see [_lastConnectedDeviceId]'s doc. */
    fun currentRemoteDeviceId(): String? = _lastConnectedDeviceId.value?.takeIf { linkByDevice.containsKey(it) }

    /** Tears down every currently-connected peer. */
    fun disconnect() {
        for (deviceId in linkByDevice.keys.toList()) disconnect(deviceId)
        recomputeConnectionState()
    }

    /** Tears down the live connection to one specific peer, if any (e.g. after
     *  `trust.revoke`) — leaves every other peer untouched. */
    fun disconnect(deviceId: String) {
        runCatching { runEngine { bridge.disconnect(deviceId) } }
        recomputeConnectionState()
    }

    fun shutdown() {
        disconnect()
        stopListening()
        for (conn in links.keys.toList()) closeLink(conn, notifyEngine = false)
        events.close()
        trustChanged.close()
        scope.cancel()
    }

    companion object {
        const val DEFAULT_PORT = 7913

        /** The two advertisement formats in use: the Mac's (base64 of the first 8 digest bytes) and this app's
         *  (first 16 characters of the unpadded base64 of the whole SHA-256 digest). */
        internal fun fingerprintMatches(advertised: String?, publicKey: ByteArray): Boolean {
            if (advertised == null) return false
            val digest = MessageDigest.getInstance("SHA-256").digest(publicKey)
            val macStyle = java.util.Base64.getEncoder().encodeToString(digest.copyOf(8))
            val androidStyle = java.util.Base64.getEncoder().withoutPadding().encodeToString(digest).take(16)
            return advertised == macStyle || advertised == androidStyle
        }

        private const val MAX_PENDING_INBOUND = 32
        private const val MAX_PENDING_INBOUND_PER_HOST = 4
        private const val LISTEN_BIND_ATTEMPTS = 5
        private const val LISTEN_BIND_RETRY_DELAY_MS = 500L
        private const val CONNECT_TIMEOUT_MS = 10_000
        private const val TICK_INTERVAL_MS = 1_000L
        private const val READ_BUFFER_BYTES = 64 * 1024

        /** A peer that stops reading is dropped once this much is waiting for it (a frame may be up to 16 MiB). */
        private const val MAX_QUEUED_WRITE_BYTES = 64L * 1024 * 1024
    }
}
