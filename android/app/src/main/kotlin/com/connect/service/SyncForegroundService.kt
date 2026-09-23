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
import com.connect.features.filetransfer.FileTransferManager
import com.connect.features.media.MediaControlBridge
import com.connect.features.screenmirror.ScreenMirrorState
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
    private lateinit var fileTransferManager: FileTransferManager
    private lateinit var mediaControlBridge: MediaControlBridge
    private lateinit var clipboardSyncManager: ClipboardSyncManager
    private lateinit var dndSyncManager: DndSyncManager
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    override fun onCreate() {
        super.onCreate()
        IdentityKeyStore.ensureInitialized(applicationContext)
        val identity = IdentityKeyStore.getInstance(applicationContext)
        val trustedDevices = TrustedDevicesStore.getInstance(applicationContext)
        val messageRouter = MessageRouter()
        screenMirrorState.register(messageRouter)
        transportManager = TransportManager(
            context = applicationContext,
            identityKeyStore = identity,
            trustedDevicesStore = trustedDevices,
            messageRouter = messageRouter
        )
        fileTransferManager = FileTransferManager(
            context = applicationContext,
            identityKeyStore = identity,
            transportManager = transportManager,
            messageRouter = messageRouter
        )
        mediaControlBridge = MediaControlBridge(
            context = applicationContext,
            messageRouter = messageRouter,
            transportManager = transportManager,
            identityKeyStore = identity,
            remoteDeviceIdProvider = { transportManager.currentRemoteDeviceId() }
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

    /** Android only ever listens for an inbound connection (`transportManager.listen()`)
     *  — on-LAN discovery/dialing is entirely Mac-initiated (Bonjour browse + `NWConnection`).
     *  That has no equivalent once the two devices aren't on the same LAN/mDNS domain (e.g.
     *  different networks bridged only by a Tailscale tunnel), so there is no path back to
     *  CONNECTED at all in that case unless *something* dials out. This loop is that
     *  something: while disconnected, and only if the user configured a fallback address for
     *  a trusted device (see `TrustedDevice.fallbackHost`, set from the Paired Devices UI),
     *  periodically attempt an outbound `connect()` to it directly, bypassing discovery.
     *  Checking `connectionState == DISCONNECTED` immediately before each attempt is what
     *  keeps this from piling up overlapping attempts: a connect in progress (or already
     *  succeeded) moves off `DISCONNECTED` until it fails, per `TransportManager.connect`. */
    private fun runFallbackDialLoop(trustedDevices: TrustedDevicesStore) {
        serviceScope.launch {
            while (isActive) {
                delay(FALLBACK_DIAL_INTERVAL_MS)
                if (transportManager.connectionState.value != ConnectionState.DISCONNECTED) continue

                val target = trustedDevices.allDevices().firstOrNull { !it.fallbackHost.isNullOrBlank() }
                    ?: continue
                transportManager.connect(
                    host = target.fallbackHost!!,
                    port = TransportManager.DEFAULT_PORT,
                    remoteStaticPublicKey = target.publicKey
                )
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
        fileTransferManager.shutdown()
        mediaControlBridge.stop()
        dndSyncManager.stop()
        clipboardSyncManager.stop()
        transportManager.shutdown()
        if (TransportManagerHolder.instance === transportManager) {
            TransportManagerHolder.instance = null
        }
        serviceScope.cancel()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder = binder

    fun transportManager(): TransportManager = transportManager

    fun fileTransferManager(): FileTransferManager = fileTransferManager

    fun dndSyncManager(): DndSyncManager = dndSyncManager

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
    }
}
