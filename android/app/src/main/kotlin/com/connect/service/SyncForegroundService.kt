package com.connect.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.connect.R
import com.connect.crypto.IdentityKeyStore
import com.connect.crypto.TrustedDevicesStore
import com.connect.features.clipboard.ClipboardSyncManager
import com.connect.features.dnd.DndSyncManager
import com.connect.features.media.MediaControlBridge
import com.connect.features.notifications.NotificationMirrorReceiver
import com.connect.features.screenmirror.ScreenMirrorState
import com.connect.features.trust.RosterGossipManager
import com.connect.protocol.detectDeviceType
import com.connect.transport.ConnectionState
import com.connect.transport.MessageRouter
import com.connect.transport.TransportManager
import com.connect.transport.TransportManagerHolder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Foreground service that owns the [TransportManager] for the lifetime of the app,
 * so the device keeps listening/reconnecting to its paired Mac even while no UI is
 * visible. Runs with a persistent low-priority "Connect is running" notification, as
 * required for a `dataSync`-typed foreground service.
 */
class SyncForegroundService : Service() {

    private lateinit var transportManager: TransportManager
    val screenMirrorState = ScreenMirrorState()
    private lateinit var mediaControlBridge: MediaControlBridge
    private lateinit var clipboardSyncManager: ClipboardSyncManager
    private lateinit var dndSyncManager: DndSyncManager
    private lateinit var rosterGossipManager: RosterGossipManager
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    override fun onCreate() {
        super.onCreate()
        IdentityKeyStore.ensureInitialized(applicationContext)
        val identity = IdentityKeyStore.getInstance(applicationContext)
        val trustedDevices = TrustedDevicesStore.getInstance(applicationContext)
        val messageRouter = MessageRouter()
        val deviceType = detectDeviceType(applicationContext)
        screenMirrorState.register(messageRouter)
        transportManager = TransportManager(
            context = applicationContext,
            identityKeyStore = identity,
            trustedDevicesStore = trustedDevices,
            messageRouter = messageRouter,
            deviceType = deviceType
        )
        mediaControlBridge = MediaControlBridge(
            context = applicationContext,
            messageRouter = messageRouter,
            transportManager = transportManager,
            identityKeyStore = identity
        )
        TransportManagerHolder.instance = transportManager
        clipboardSyncManager = ClipboardSyncManager(
            context = applicationContext,
            transportManager = transportManager,
            messageRouter = messageRouter,
            deviceId = identity.deviceId,
            scope = serviceScope
        )
        dndSyncManager = DndSyncManager(
            context = applicationContext,
            identityKeyStore = identity,
            transportManager = transportManager,
            messageRouter = messageRouter,
            scope = serviceScope
        )
        dndSyncManager.start()
        NotificationMirrorReceiver.instance = NotificationMirrorReceiver(
            context = applicationContext,
            transportManager = transportManager,
            identityKeyStore = identity,
            messageRouter = messageRouter,
            scope = serviceScope
        )
        rosterGossipManager = RosterGossipManager(
            transportManager = transportManager,
            trustedDevicesStore = trustedDevices,
            identityKeyStore = identity,
            messageRouter = messageRouter,
            scope = serviceScope,
            deviceName = Build.MODEL ?: "Android device",
            deviceType = deviceType
        )

        // Start/stop clipboard sync in lockstep with the transport connection, same as
        // the loop-suppression contract in schema/message-types.md requires.
        transportManager.connectionState
            .onEach { state ->
                if (state == ConnectionState.CONNECTED) {
                    clipboardSyncManager.start()
                    // Two devices that were apart can each have a different real DND
                    // state with neither side having done anything wrong — nothing
                    // synced them yet. Report on every fresh connection (not just once
                    // ever) so a reconnect after being out of range reconciles too; see
                    // DndSyncManager.reportInitialSyncState's doc for why this can't be
                    // a plain reportCurrentState() call.
                    dndSyncManager.reportInitialSyncState()
                } else {
                    clipboardSyncManager.stop()
                }
            }
            .launchIn(serviceScope)

        runFallbackDialLoop(trustedDevices)
        runDndResyncLoop()
        runRosterResyncLoop()
    }

    /** Self-healing backstop for roster gossip, on top of the event-driven paths (a fresh
     *  connection, or a brand-new pairing): periodically re-broadcasts the full local
     *  roster to every connected peer. Mirrors [runDndResyncLoop] — safe to call
     *  repeatedly, since re-adding an already-trusted device is a no-op (see
     *  `RosterGossipManager.handleRosterUpdate`). */
    private fun runRosterResyncLoop() {
        serviceScope.launch {
            while (isActive) {
                delay(ROSTER_RESYNC_INTERVAL_MS)
                rosterGossipManager.periodicResync()
            }
        }
    }

    /** Self-healing backstop for DND sync, on top of the event-driven paths
     *  ([DndSyncManager.reportCurrentState] on a local change, `reportInitialSyncState()` on
     *  every fresh connect): periodically re-sends this device's current state as another
     *  `isInitialSync` OR-merge report while connected. Event-driven sync alone has no
     *  recovery if a single message is ever dropped, sent while transiently disconnected, or
     *  missed by a race — the two devices then stay silently mismatched indefinitely, which is
     *  exactly the failure mode several bugs in this DND feature turned out to be. Reusing the
     *  OR-merge (rather than a plain mirror) keeps this safe to call repeatedly: it only acts
     *  when there's a genuine disagreement to fix, so healthy periods are no-ops. */
    private fun runDndResyncLoop() {
        serviceScope.launch {
            while (isActive) {
                delay(DND_RESYNC_INTERVAL_MS)
                if (transportManager.connectionState.value == ConnectionState.CONNECTED) {
                    dndSyncManager.reportInitialSyncState()
                }
            }
        }
    }

    /** Android only ever listens for inbound connections (`transportManager.listen()`) on
     *  the LAN — Mac-initiated discovery/dialing (Bonjour browse + `NWConnection`) doesn't
     *  reach a device that isn't on the same LAN/mDNS domain (e.g. different networks
     *  bridged only by a Tailscale tunnel), so there is no path to a connection at all in
     *  that case unless *something* dials out. This loop is that something: dials *every*
     *  trusted device with a configured fallback address (see `TrustedDevice.fallbackHost`,
     *  set from the Paired Devices UI) that isn't already connected — not just the first
     *  one found while fully idle, since with a mesh this device may already be connected
     *  to some trusted devices while still needing to fallback-dial others.
     *  `TransportManager.connect`'s own dedupe guard (skips if already connected/dialing to
     *  that exact `deviceId`) is what keeps this from piling up overlapping attempts. */
    private fun runFallbackDialLoop(trustedDevices: TrustedDevicesStore) {
        serviceScope.launch {
            while (isActive) {
                delay(FALLBACK_DIAL_INTERVAL_MS)
                val connected = transportManager.connectedDeviceIds.value
                for (target in trustedDevices.allDevices()) {
                    val host = target.fallbackHost
                    if (host.isNullOrBlank() || target.deviceId in connected) continue
                    transportManager.connect(
                        host = host,
                        port = TransportManager.DEFAULT_PORT,
                        remoteStaticPublicKey = target.publicKey,
                        deviceId = target.deviceId
                    )
                }
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIFICATION_ID, buildNotification())
        transportManager.listen()
        mediaControlBridge.start()
        return START_STICKY
    }

    override fun onDestroy() {
        mediaControlBridge.stop()
        dndSyncManager.stop()
        clipboardSyncManager.stop()
        transportManager.shutdown()
        if (TransportManagerHolder.instance === transportManager) {
            TransportManagerHolder.instance = null
        }
        NotificationMirrorReceiver.instance = null
        serviceScope.cancel()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder = binder

    fun transportManager(): TransportManager = transportManager

    fun dndSyncManager(): DndSyncManager = dndSyncManager

    fun rosterGossipManager(): RosterGossipManager = rosterGossipManager

    inner class LocalBinder : android.os.Binder() {
        fun service(): SyncForegroundService = this@SyncForegroundService
    }

    private val binder = LocalBinder()

    private fun buildNotification(): Notification {
        val channelId = ensureChannel()
        return NotificationCompat.Builder(this, channelId)
            .setContentTitle(getString(R.string.sync_notification_title))
            .setContentText(getString(R.string.sync_notification_text))
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .build()
    }

    private fun ensureChannel(): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            val channel = NotificationChannel(
                CHANNEL_ID,
                getString(R.string.sync_notification_channel),
                NotificationManager.IMPORTANCE_LOW
            )
            manager.createNotificationChannel(channel)
        }
        return CHANNEL_ID
    }

    companion object {
        private const val CHANNEL_ID = "connect_sync"
        /** Not private: [com.connect.features.notifications.NotificationListenerImpl]
         *  needs this to specifically exclude the persistent "Connect is running"
         *  notification from mirroring, without excluding every notification this
         *  app posts (e.g. a manual test notification). */
        const val NOTIFICATION_ID = 1001
        private const val FALLBACK_DIAL_INTERVAL_MS = 15_000L
        private const val DND_RESYNC_INTERVAL_MS = 60_000L
        private const val ROSTER_RESYNC_INTERVAL_MS = 300_000L
    }
}
