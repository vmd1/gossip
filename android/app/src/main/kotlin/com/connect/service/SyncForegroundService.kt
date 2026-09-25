package com.connect.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.util.Log
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.connect.R
import com.connect.crypto.IdentityKeyStore
import com.connect.crypto.TrustedDevicesStore
import com.connect.features.clipboard.ClipboardSyncManager
import com.connect.features.dnd.DndSyncManager
import com.connect.features.media.MediaControlBridge
import com.connect.features.notifications.NotificationMirrorReceiver
import com.connect.features.proximity.BLEProximityMonitor
import com.connect.features.proximity.LockOnLeaveManager
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
    private lateinit var bleProximityMonitor: BLEProximityMonitor
    private lateinit var lockOnLeaveManager: LockOnLeaveManager
    private var shizukuManager: com.connect.features.hotspot.ShizukuManager? = null
    private var hotspotGattServer: com.connect.features.hotspot.HotspotGattServer? = null
    private lateinit var hotspotStateManager: com.connect.features.hotspot.HotspotStateManager
    private lateinit var autoHotspotRequestManager: com.connect.features.hotspot.AutoHotspotRequestManager
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
        shizukuManager = com.connect.features.hotspot.ShizukuManager(applicationContext).also { it.start() }
        clipboardSyncManager = ClipboardSyncManager(
            context = applicationContext,
            transportManager = transportManager,
            messageRouter = messageRouter,
            deviceId = identity.deviceId,
            scope = serviceScope,
            shizukuManager = shizukuManager
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
        bleProximityMonitor = BLEProximityMonitor(
            context = applicationContext,
            identityKeyStore = identity,
            trustedDevicesStore = trustedDevices,
            deviceType = deviceType
        )
        // Seed the "hotspot available" capability bit from the persisted toggle before
        // the first advertise — the toggle's own UI callback only fires on a live
        // change, so a phone that already had this enabled from a previous session
        // needs this to advertise the bit correctly from service startup, not just
        // after the user re-touches the switch.
        bleProximityMonitor.setHotspotAvailable(com.connect.onboarding.OnboardingPreferences(applicationContext).provideHotspotEnabled)
        // Same reasoning, for the "hotspot currently on" bit: HotspotStateManager's own
        // WIFI_AP_STATE_CHANGED_ACTION receiver only fires on a live change, so a phone
        // whose hotspot was already on before this service (re)started needs this seed
        // to advertise the bit correctly from the start.
        bleProximityMonitor.setHotspotOn(com.connect.features.hotspot.TetherHelper.isHotspotEnabled(applicationContext))
        if (bleProximityMonitor.hasRequiredPermissions()) {
            bleProximityMonitor.start()
        }
        // GATT server (provider/peripheral role) — phone-only, per
        // docs/ble-hotspot-protocol.md's "GATT roles": a tablet/Mac only ever requests,
        // never provides. Started unconditionally on a phone (not gated on the "Provide
        // Instant Hotspot" toggle) — the toggle instead gates the advertisement's
        // capability bit (above) and every individual request inside the server itself
        // (defense in depth), matching that doc's "not advertise at all, not just refuse
        // requests after the fact" requirement without needing to restart this server
        // every time the toggle flips.
        if (deviceType == com.connect.protocol.DeviceType.ANDROID_PHONE) {
            hotspotGattServer = com.connect.features.hotspot.HotspotGattServer(
                context = applicationContext,
                identityKeyStore = identity,
                trustedDevicesStore = trustedDevices,
                scope = serviceScope,
                shizukuManager = shizukuManager
            ).also { it.start() }
        }
        hotspotStateManager = com.connect.features.hotspot.HotspotStateManager(
            context = applicationContext,
            identityKeyStore = identity,
            transportManager = transportManager,
            messageRouter = messageRouter,
            scope = serviceScope,
            deviceType = deviceType,
            shizukuManager = shizukuManager,
            bleProximityMonitor = bleProximityMonitor
        )
        hotspotStateManager.start()
        lockOnLeaveManager = LockOnLeaveManager(
            context = applicationContext,
            trustedDevicesStore = trustedDevices,
            bleProximityMonitor = bleProximityMonitor,
            messageRouter = messageRouter,
            transportManager = transportManager,
            identityKeyStore = identity,
            localDeviceType = deviceType,
            scope = serviceScope
        )
        lockOnLeaveManager.start()
        autoHotspotRequestManager = com.connect.features.hotspot.AutoHotspotRequestManager(
            context = applicationContext,
            identityKeyStore = identity,
            trustedDevicesStore = trustedDevices,
            bleProximityMonitor = bleProximityMonitor,
            onboardingPreferences = com.connect.onboarding.OnboardingPreferences(applicationContext),
            deviceType = deviceType,
            scope = serviceScope
        )
        autoHotspotRequestManager.start()

        // TEMPORARY debug hook to verify TetherHelper works end-to-end via adb before the
        // real GATT request path exists — remove once Instant Hotspot's GATT channel lands.
        registerReceiver(
            object : android.content.BroadcastReceiver() {
                override fun onReceive(ctx: android.content.Context, intent: Intent) {
                    val enable = intent.getBooleanExtra("enable", true)
                    serviceScope.launch {
                        val preferredMechanismId = com.connect.onboarding.OnboardingPreferences(applicationContext)
                            .preferredHotspotMechanismId
                        val result = com.connect.features.hotspot.TetherHelper.setHotspotEnabled(
                            applicationContext, enable, shizukuManager, preferredMechanismId = preferredMechanismId
                        )
                        Log.i("HotspotDebug", "setHotspotEnabled(enable=$enable) -> $result")
                    }
                }
            },
            IntentFilter("com.connect.DEBUG_TOGGLE_HOTSPOT"),
            android.content.Context.RECEIVER_EXPORTED
        )

        // TEMPORARY debug hook to flip "Provide Instant Hotspot" without touching the
        // real UI, for live end-to-end GATT testing — remove once the toggle's real UI
        // is exercised directly instead.
        registerReceiver(
            object : android.content.BroadcastReceiver() {
                override fun onReceive(ctx: android.content.Context, intent: Intent) {
                    val enable = intent.getBooleanExtra("enable", true)
                    com.connect.onboarding.OnboardingPreferences(applicationContext).provideHotspotEnabled = enable
                    bleProximityMonitor.setHotspotAvailable(enable)
                    Log.i("HotspotDebug", "provideHotspotEnabled -> $enable")
                }
            },
            IntentFilter("com.connect.DEBUG_SET_PROVIDE_HOTSPOT"),
            android.content.Context.RECEIVER_EXPORTED
        )

        // TEMPORARY debug hook to verify HotspotCredentialReader's reflection-based
        // getSoftApConfiguration() call against a real device before the real GATT
        // response path exists — remove once Instant Hotspot's credential-delivery path
        // is live-tested end-to-end via GATT instead.
        registerReceiver(
            object : android.content.BroadcastReceiver() {
                override fun onReceive(ctx: android.content.Context, intent: Intent) {
                    val credentials = com.connect.features.hotspot.HotspotCredentialReader.readCredentials(applicationContext, shizukuManager)
                    Log.i("HotspotDebug", "readCredentials() -> $credentials")
                }
            },
            IntentFilter("com.connect.DEBUG_READ_HOTSPOT_CREDENTIALS"),
            android.content.Context.RECEIVER_EXPORTED
        )

        // TEMPORARY debug hook to trigger the one-time Shizuku permission dialog before
        // there's a real onboarding UI for it — remove once that UI lands.
        registerReceiver(
            object : android.content.BroadcastReceiver() {
                override fun onReceive(ctx: android.content.Context, intent: Intent) {
                    Log.i("HotspotDebug", "Shizuku state before request: ${shizukuManager?.state?.value}")
                    shizukuManager?.requestPermission()
                }
            },
            IntentFilter("com.connect.DEBUG_REQUEST_SHIZUKU"),
            android.content.Context.RECEIVER_EXPORTED
        )

        // TEMPORARY debug hooks to verify ShizukuClipboardReader's background read works —
        // remove once this has real test coverage.
        registerReceiver(
            object : android.content.BroadcastReceiver() {
                override fun onReceive(ctx: android.content.Context, intent: Intent) {
                    val text = intent.getStringExtra("text") ?: return
                    (applicationContext.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager)
                        .setPrimaryClip(android.content.ClipData.newPlainText("debug", text))
                    Log.i("ClipboardDebug", "Set clipboard to: $text")
                }
            },
            IntentFilter("com.connect.DEBUG_SET_CLIPBOARD"),
            android.content.Context.RECEIVER_EXPORTED
        )
        registerReceiver(
            object : android.content.BroadcastReceiver() {
                override fun onReceive(ctx: android.content.Context, intent: Intent) {
                    val focusedRead = runCatching {
                        (applicationContext.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager)
                            .primaryClip?.getItemAt(0)?.coerceToText(applicationContext)?.toString()
                    }.getOrNull()
                    val shizukuRead = com.connect.features.clipboard.ShizukuClipboardReader.readText()
                    Log.i("ClipboardDebug", "Focus-gated read: $focusedRead | Shizuku read: $shizukuRead")
                }
            },
            IntentFilter("com.connect.DEBUG_READ_CLIPBOARD"),
            android.content.Context.RECEIVER_EXPORTED
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
                    // Same reasoning: a Mac that reconnects after being disconnected
                    // (or missed the original event-driven publish to any other race)
                    // otherwise never learns this device is currently playing anything
                    // until the *next* playback/metadata change, which might be a long
                    // time or never — mediaControlBridge.start() only ever published
                    // once, at service startup, with no reconnect-triggered resend.
                    mediaControlBridge.resyncNowPlaying()
                    // Same reasoning as dndSyncManager.reportInitialSyncState above: a
                    // peer that reconnects (or missed the original event-driven report
                    // to any race) shouldn't have to wait for this phone's *next*
                    // hotspot toggle to learn its current state.
                    hotspotStateManager.periodicResync()
                } else {
                    clipboardSyncManager.stop()
                }
            }
            .launchIn(serviceScope)

        runFallbackDialLoop(trustedDevices)
        runDndResyncLoop()
        runRosterResyncLoop()
        runMediaResyncLoop()
        runHotspotStateResyncLoop()
    }

    /** Self-healing backstop for `hotspot.state_update`, on top of the event-driven
     *  publish (a local `WIFI_AP_STATE_CHANGED_ACTION`) and the on-connect resend above:
     *  periodically re-sends this phone's current hotspot state while connected. Mirrors
     *  [runDndResyncLoop]/[runMediaResyncLoop] — a no-op on a tablet/Mac (never
     *  originates this) and cheap on a phone regardless of whether the state has
     *  actually changed recently. */
    private fun runHotspotStateResyncLoop() {
        serviceScope.launch {
            while (isActive) {
                delay(DND_RESYNC_INTERVAL_MS)
                if (transportManager.connectionState.value == ConnectionState.CONNECTED) {
                    hotspotStateManager.periodicResync()
                }
            }
        }
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

    /** Self-healing backstop for `media.nowplaying`, on top of the event-driven publish
     *  (a playback/metadata change) and the on-connect resend above: periodically
     *  re-sends this device's current now-playing snapshot while connected. Mirrors
     *  [runDndResyncLoop] — a no-op both when nothing is playing and when a peer
     *  already has this exact snapshot, since it's the same publish a real change
     *  would trigger. */
    private fun runMediaResyncLoop() {
        serviceScope.launch {
            while (isActive) {
                delay(DND_RESYNC_INTERVAL_MS)
                if (transportManager.connectionState.value == ConnectionState.CONNECTED) {
                    mediaControlBridge.resyncNowPlaying()
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
        bleProximityMonitor.stop()
        hotspotStateManager.stop()
        lockOnLeaveManager.stop()
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

    fun bleProximityMonitor(): BLEProximityMonitor = bleProximityMonitor

    fun hotspotStateManager(): com.connect.features.hotspot.HotspotStateManager = hotspotStateManager

    /** Exposed so the home screen can show a "your screen is being mirrored" indicator —
     *  see [com.connect.features.screenmirror.ScreenMirrorState]'s own doc comment, which
     *  already anticipated this accessor ("exists purely so a future 'Mirroring active'
     *  indicator... has something to observe") but nothing had wired it up yet; found
     *  during this handoff's Phase 3 parity audit (`HANDOFF_ONBOARDING_AND_POLISH.md`) —
     *  the state was tracked correctly the whole time, just never surfaced anywhere. */
    fun screenMirrorState(): ScreenMirrorState = screenMirrorState

    /** Null until Shizuku's binder lifecycle initializes it in [onCreate] — practically
     *  always non-null by the time a bound client reads this, since binding itself is
     *  already async. Exposed so onboarding's hotspot-mechanism-test step (see
     *  `HANDOFF_ONBOARDING_AND_POLISH.md` Phase 2) can call [com.connect.features.hotspot.
     *  TetherHelper.probeMechanisms] with the real, running instance instead of
     *  constructing a second one. */
    fun shizukuManager(): com.connect.features.hotspot.ShizukuManager? = shizukuManager

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
