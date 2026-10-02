package dev.vmd1.gossip.service

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
import dev.vmd1.gossip.R
import dev.vmd1.gossip.crypto.IdentityKeyStore
import dev.vmd1.gossip.crypto.TrustedDevicesStore
import dev.vmd1.gossip.features.clipboard.ClipboardSyncManager
import dev.vmd1.gossip.features.dnd.DndSyncManager
import dev.vmd1.gossip.features.media.MediaControlBridge
import dev.vmd1.gossip.features.notifications.NotificationMirrorReceiver
import dev.vmd1.gossip.features.proximity.BLEProximityMonitor
import dev.vmd1.gossip.features.proximity.LockOnLeaveManager
import dev.vmd1.gossip.features.screenmirror.ScreenMirrorState
import dev.vmd1.gossip.features.trust.RosterGossipManager
import dev.vmd1.gossip.protocol.detectDeviceType
import dev.vmd1.gossip.transport.ConnectionState
import dev.vmd1.gossip.transport.MessageRouter
import dev.vmd1.gossip.transport.TransportManager
import dev.vmd1.gossip.transport.TransportManagerHolder
import dev.vmd1.gossip.transport.newlyConnectedPeers
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.isActive
import dev.vmd1.gossip.protocol.Envelope
import dev.vmd1.gossip.protocol.MessageType
import kotlinx.coroutines.launch

/**
 * Foreground service that owns the [TransportManager] for the lifetime of the app,
 * so the device keeps listening/reconnecting to its paired Mac even while no UI is
 * visible. Runs with a persistent low-priority "Gossip is running" notification, as
 * required for a `dataSync`-typed foreground service.
 */
class SyncForegroundService : Service() {

    private lateinit var transportManager: TransportManager
    lateinit var screenMirrorState: ScreenMirrorState
    lateinit var controlSessionState: dev.vmd1.gossip.features.universalcontrol.ControlSessionState
    private lateinit var mediaControlBridge: MediaControlBridge
    private lateinit var clipboardSyncManager: ClipboardSyncManager
    private lateinit var dndSyncManager: DndSyncManager
    private lateinit var rosterGossipManager: RosterGossipManager
    private lateinit var bleProximityMonitor: BLEProximityMonitor
    private lateinit var lockOnLeaveManager: LockOnLeaveManager
    private var shizukuManager: dev.vmd1.gossip.features.hotspot.ShizukuManager? = null
    private var hotspotGattServer: dev.vmd1.gossip.features.hotspot.HotspotGattServer? = null
    private lateinit var hotspotStateManager: dev.vmd1.gossip.features.hotspot.HotspotStateManager
    private lateinit var ringManager: dev.vmd1.gossip.features.find.RingManager
    private lateinit var batterySyncManager: dev.vmd1.gossip.features.battery.BatterySyncManager
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    override fun onCreate() {
        super.onCreate()
        IdentityKeyStore.ensureInitialized(applicationContext)
        val identity = IdentityKeyStore.getInstance(applicationContext)
        val trustedDevices = TrustedDevicesStore.getInstance(applicationContext)
        val featureSettings = dev.vmd1.gossip.features.settings.FeatureSettings.getInstance(applicationContext)
        val messageRouter = MessageRouter(isMessageAllowed = featureSettings::isMessageAllowed)
        val deviceType = detectDeviceType(applicationContext)
        screenMirrorState = ScreenMirrorState(
            selfId = identity.deviceId,
            scope = serviceScope,
            shizukuReady = { shizukuManager?.state?.value == dev.vmd1.gossip.features.hotspot.ShizukuManager.State.CONNECTED },
            send = { envelope -> serviceScope.launch { runCatching { transportManager.send(envelope) } } },
            sessionFactory = { sessionId, options, onEnded ->
                dev.vmd1.gossip.features.screenmirror.ScreenBridge(applicationContext, sessionId, options, onEnded)
            },
            logReadyToken = applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0,
            isEnabled = { featureSettings.isEnabled(dev.vmd1.gossip.features.settings.Feature.SCREEN_MIRRORING) }
        )
        screenMirrorState.register(messageRouter)
        controlSessionState = dev.vmd1.gossip.features.universalcontrol.ControlSessionState(
            selfId = identity.deviceId,
            scope = serviceScope,
            shizukuReady = { shizukuManager?.state?.value == dev.vmd1.gossip.features.hotspot.ShizukuManager.State.CONNECTED },
            send = { envelope -> serviceScope.launch { runCatching { transportManager.send(envelope) } } },
            sessionFactory = { sessionId, secret, onEnded ->
                dev.vmd1.gossip.features.universalcontrol.ControlBridge(applicationContext, sessionId, secret, onEnded)
            },
            isEnabled = { featureSettings.isEnabled(dev.vmd1.gossip.features.settings.Feature.UNIVERSAL_CONTROL) }
        )
        controlSessionState.register(messageRouter)
        transportManager = TransportManager(
            context = applicationContext,
            identityKeyStore = identity,
            trustedDevicesStore = trustedDevices,
            messageRouter = messageRouter,
            deviceType = deviceType,
            isMessageAllowed = featureSettings::isMessageAllowed
        )
        mediaControlBridge = MediaControlBridge(
            context = applicationContext,
            messageRouter = messageRouter,
            transportManager = transportManager,
            identityKeyStore = identity
        )
        TransportManagerHolder.instance = transportManager
        // The notification listener may have connected before the transport existed; let it register
        // its reply/dismiss handlers now.
        dev.vmd1.gossip.features.notifications.NotificationListenerImpl.active?.ensureHandlersRegistered()
        shizukuManager = dev.vmd1.gossip.features.hotspot.ShizukuManager(applicationContext).also { it.start() }
        clipboardSyncManager = ClipboardSyncManager(
            context = applicationContext,
            transportManager = transportManager,
            messageRouter = messageRouter,
            deviceId = identity.deviceId,
            scope = serviceScope,
            shizukuManager = shizukuManager,
            isEnabled = { featureSettings.isEnabled(dev.vmd1.gossip.features.settings.Feature.CLIPBOARD) }
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
        // The advertised "hotspot available" capability needs both the provide-hotspot policy and the
        // Instant Hotspot feature toggle; recomputed whenever the feature toggle changes.
        serviceScope.launch {
            featureSettings.disabled.collect {
                bleProximityMonitor.setHotspotAvailable(
                    dev.vmd1.gossip.onboarding.OnboardingPreferences(applicationContext).provideHotspotEnabled &&
                        featureSettings.isEnabled(dev.vmd1.gossip.features.settings.Feature.HOTSPOT)
                )
            }
        }
        // Same reasoning, for the "hotspot currently on" bit: HotspotStateManager's own
        // WIFI_AP_STATE_CHANGED_ACTION receiver only fires on a live change, so a phone
        // whose hotspot was already on before this service (re)started needs this seed
        // to advertise the bit correctly from the start.
        bleProximityMonitor.setHotspotOn(dev.vmd1.gossip.features.hotspot.TetherHelper.isHotspotEnabled(applicationContext))
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
        if (deviceType == dev.vmd1.gossip.protocol.DeviceType.ANDROID_PHONE) {
            hotspotGattServer = dev.vmd1.gossip.features.hotspot.HotspotGattServer(
                context = applicationContext,
                identityKeyStore = identity,
                trustedDevicesStore = trustedDevices,
                scope = serviceScope,
                shizukuManager = shizukuManager
            ).also { it.start() }
        }
        hotspotStateManager = dev.vmd1.gossip.features.hotspot.HotspotStateManager(
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
            scope = serviceScope,
            isEnabled = { featureSettings.isEnabled(dev.vmd1.gossip.features.settings.Feature.LOCK_ON_LEAVE) }
        )
        lockOnLeaveManager.start()

        // Find my device: rings on `device.ring`; a notification with a Stop action silences it.
        ringManager = dev.vmd1.gossip.features.find.RingManager(
            messageRouter = messageRouter,
            ringer = dev.vmd1.gossip.features.find.AlarmRinger(applicationContext),
            scope = serviceScope,
            onRingingChanged = { ringing -> showRingNotification(ringing) },
            selfId = identity.deviceId,
            send = { envelope -> serviceScope.launch { runCatching { transportManager.send(envelope) } } }
        )
        ringManager.start()
        registerReceiver(
            object : android.content.BroadcastReceiver() {
                override fun onReceive(ctx: android.content.Context, intent: Intent) { ringManager.stopRinging() }
            },
            IntentFilter(ACTION_STOP_RING),
            android.content.Context.RECEIVER_NOT_EXPORTED
        )

        // Battery sync: broadcasts this device's level (reconciled on connect + every 60s), tracks
        // peers' levels for the paired-devices list, alerts when a peer runs low.
        batterySyncManager = dev.vmd1.gossip.features.battery.BatterySyncManager(
            context = applicationContext,
            deviceId = identity.deviceId,
            messageRouter = messageRouter,
            send = { envelope -> transportManager.send(envelope) },
            scope = serviceScope,
            onLowBattery = { senderId, level -> showLowBatteryNotification(senderId, level) },
            isEnabled = { featureSettings.isEnabled(dev.vmd1.gossip.features.settings.Feature.BATTERY) }
        )
        batterySyncManager.start()

        // TEMPORARY debug hook to verify TetherHelper works end-to-end via adb before the
        // real GATT request path exists — remove once Instant Hotspot's GATT channel lands.
        registerReceiver(
            object : android.content.BroadcastReceiver() {
                override fun onReceive(ctx: android.content.Context, intent: Intent) {
                    val enable = intent.getBooleanExtra("enable", true)
                    serviceScope.launch {
                        val preferredMechanismId = dev.vmd1.gossip.onboarding.OnboardingPreferences(applicationContext)
                            .preferredHotspotMechanismId
                        val result = dev.vmd1.gossip.features.hotspot.TetherHelper.setHotspotEnabled(
                            applicationContext, enable, shizukuManager, preferredMechanismId = preferredMechanismId
                        )
                        Log.i("HotspotDebug", "setHotspotEnabled(enable=$enable) -> $result")
                    }
                }
            },
            IntentFilter("dev.vmd1.gossip.DEBUG_TOGGLE_HOTSPOT"),
            android.content.Context.RECEIVER_EXPORTED
        )

        // TEMPORARY debug hook to flip "Provide Instant Hotspot" without touching the
        // real UI, for live end-to-end GATT testing — remove once the toggle's real UI
        // is exercised directly instead.
        registerReceiver(
            object : android.content.BroadcastReceiver() {
                override fun onReceive(ctx: android.content.Context, intent: Intent) {
                    val enable = intent.getBooleanExtra("enable", true)
                    dev.vmd1.gossip.onboarding.OnboardingPreferences(applicationContext).provideHotspotEnabled = enable
                    bleProximityMonitor.setHotspotAvailable(enable)
                    Log.i("HotspotDebug", "provideHotspotEnabled -> $enable")
                }
            },
            IntentFilter("dev.vmd1.gossip.DEBUG_SET_PROVIDE_HOTSPOT"),
            android.content.Context.RECEIVER_EXPORTED
        )

        // TEMPORARY debug hook to verify HotspotCredentialReader's reflection-based
        // getSoftApConfiguration() call against a real device before the real GATT
        // response path exists — remove once Instant Hotspot's credential-delivery path
        // is live-tested end-to-end via GATT instead.
        registerReceiver(
            object : android.content.BroadcastReceiver() {
                override fun onReceive(ctx: android.content.Context, intent: Intent) {
                    val credentials = dev.vmd1.gossip.features.hotspot.HotspotCredentialReader.readCredentials(applicationContext, shizukuManager)
                    Log.i("HotspotDebug", "readCredentials() -> $credentials")
                }
            },
            IntentFilter("dev.vmd1.gossip.DEBUG_READ_HOTSPOT_CREDENTIALS"),
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
            IntentFilter("dev.vmd1.gossip.DEBUG_REQUEST_SHIZUKU"),
            android.content.Context.RECEIVER_EXPORTED
        )

        // TEMPORARY debug hooks (registered only in debuggable builds): inject a screen.start /
        // screen.stop envelope as if from a paired viewer, so the capture bridge can be exercised on
        // an emulator with no Mac paired. `screen.ready`'s token is logged under tag ScreenMirror.
        if (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0) {
            // Plays a 2 s 440 Hz tone on the media stream so audio capture can be verified without
            // needing a music app: `am broadcast -a dev.vmd1.gossip.DEBUG_PLAY_TONE`.
            registerReceiver(
                object : android.content.BroadcastReceiver() {
                    override fun onReceive(ctx: android.content.Context, intent: Intent) {
                        Thread {
                            val rate = 48_000
                            val samples = ShortArray(rate * 2) { (Math.sin(2 * Math.PI * 440 * it / rate) * 8000).toInt().toShort() }
                            val track = android.media.AudioTrack.Builder()
                                .setAudioAttributes(android.media.AudioAttributes.Builder()
                                    .setUsage(android.media.AudioAttributes.USAGE_MEDIA).build())
                                .setAudioFormat(android.media.AudioFormat.Builder()
                                    .setSampleRate(rate).setEncoding(android.media.AudioFormat.ENCODING_PCM_16BIT)
                                    .setChannelMask(android.media.AudioFormat.CHANNEL_OUT_MONO).build())
                                .setBufferSizeInBytes(samples.size * 2).build()
                            track.write(samples, 0, samples.size); track.play()
                            Thread.sleep(2300); track.release()
                        }.start()
                    }
                },
                IntentFilter("dev.vmd1.gossip.DEBUG_PLAY_TONE"),
                android.content.Context.RECEIVER_EXPORTED
            )
            registerReceiver(
                object : android.content.BroadcastReceiver() {
                    override fun onReceive(ctx: android.content.Context, intent: Intent) {
                        val start = intent.action == "dev.vmd1.gossip.DEBUG_SCREEN_START"
                        val payload = kotlinx.serialization.json.buildJsonObject {
                            intent.getStringExtra("sessionId")?.let { put("sessionId", kotlinx.serialization.json.JsonPrimitive(it)) }
                            for (k in listOf("maxSize", "bitRate", "maxFps")) {
                                if (intent.hasExtra(k)) put(k, kotlinx.serialization.json.JsonPrimitive(intent.getIntExtra(k, 0)))
                            }
                            if (intent.hasExtra("audio")) put("audio", kotlinx.serialization.json.JsonPrimitive(intent.getBooleanExtra("audio", false)))
                        }
                        val env = Envelope(
                            type = if (start) MessageType.SCREEN_START else MessageType.SCREEN_STOP,
                            senderId = "debug-viewer", recipientId = identity.deviceId, payload = payload
                        )
                        messageRouter.dispatch(env)
                    }
                },
                IntentFilter().apply {
                    addAction("dev.vmd1.gossip.DEBUG_SCREEN_START"); addAction("dev.vmd1.gossip.DEBUG_SCREEN_STOP")
                },
                android.content.Context.RECEIVER_EXPORTED
            )
        }

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
            IntentFilter("dev.vmd1.gossip.DEBUG_SET_CLIPBOARD"),
            android.content.Context.RECEIVER_EXPORTED
        )
        registerReceiver(
            object : android.content.BroadcastReceiver() {
                override fun onReceive(ctx: android.content.Context, intent: Intent) {
                    val focusedRead = runCatching {
                        (applicationContext.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager)
                            .primaryClip?.getItemAt(0)?.coerceToText(applicationContext)?.toString()
                    }.getOrNull()
                    val shizukuRead = dev.vmd1.gossip.features.clipboard.ShizukuClipboardReader.readText()
                    Log.i("ClipboardDebug", "Focus-gated read: $focusedRead | Shizuku read: $shizukuRead")
                }
            },
            IntentFilter("dev.vmd1.gossip.DEBUG_READ_CLIPBOARD"),
            android.content.Context.RECEIVER_EXPORTED
        )

        // Start/stop clipboard sync in lockstep with the transport connection, same as
        // the loop-suppression contract in schema/message-types.md requires.
        transportManager.connectionState
            .onEach { state ->
                if (state == ConnectionState.CONNECTED) {
                    clipboardSyncManager.start()
                } else {
                    clipboardSyncManager.stop()
                }
            }
            .launchIn(serviceScope)

        // Initial syncs fire for every *newly connected peer*, not just when the aggregate
        // state flips to CONNECTED: a second peer connecting while the first is still up
        // causes no flip, and would otherwise wait for the 60s resync loops. The sends are
        // broadcasts and idempotent, so an already-connected peer just gets a harmless repeat.
        transportManager.connectedDeviceIds
            .newlyConnectedPeers()
            .onEach {
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
                // Same reasoning for battery.update: a reconnecting peer shouldn't wait
                // for the next 1% level change to learn this device's battery.
                batterySyncManager.reportInitialSyncState()
            }
            .launchIn(serviceScope)

        runFallbackDialLoop(trustedDevices)
        runDndResyncLoop()
        runRosterResyncLoop()
        runMediaResyncLoop()
        runHotspotStateResyncLoop()
        runBatteryResyncLoop()
    }

    /** Self-healing backstop for `battery.update`, on top of the event-driven publish (a local
     *  battery change) and the on-connect resend: re-sends the current reading every 60s while
     *  connected, so a dropped or mis-timed report never leaves peers stale. */
    private fun runBatteryResyncLoop() {
        serviceScope.launch {
            while (isActive) {
                delay(DND_RESYNC_INTERVAL_MS)
                if (transportManager.connectionState.value == ConnectionState.CONNECTED) {
                    batterySyncManager.periodicResync()
                }
            }
        }
    }

    private fun showRingNotification(ringing: Boolean) {
        val manager = getSystemService(NotificationManager::class.java)
        if (!ringing) { manager.cancel(RING_NOTIFICATION_ID); return }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(NotificationChannel(RING_CHANNEL_ID, "Find my device", NotificationManager.IMPORTANCE_HIGH))
        }
        val stop = android.app.PendingIntent.getBroadcast(
            this, 0, Intent(ACTION_STOP_RING).setPackage(packageName),
            android.app.PendingIntent.FLAG_IMMUTABLE or android.app.PendingIntent.FLAG_UPDATE_CURRENT
        )
        val n = NotificationCompat.Builder(this, RING_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle("Gossip is ringing this device")
            .setContentText("A paired device asked this one to ring.")
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setOngoing(true)
            .addAction(android.R.drawable.ic_media_pause, "Stop", stop)
            .setContentIntent(stop)
            .build()
        runCatching { manager.notify(RING_NOTIFICATION_ID, n) }
    }

    private fun showLowBatteryNotification(senderId: String, level: Int) {
        val name = TrustedDevicesStore.getInstance(applicationContext).allDevices()
            .firstOrNull { it.deviceId == senderId }?.deviceName ?: "A paired device"
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(NotificationChannel(BATTERY_CHANNEL_ID, "Low battery on paired devices", NotificationManager.IMPORTANCE_DEFAULT))
        }
        val n = NotificationCompat.Builder(this, BATTERY_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setContentTitle("$name battery low")
            .setContentText("$name is at $level% and not charging.")
            .setAutoCancel(true)
            .build()
        runCatching { manager.notify(BATTERY_NOTIFICATION_BASE + (senderId.hashCode() and 0xFFFF), n) }
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
        ringManager.shutdown()
        batterySyncManager.stop()
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

    fun hotspotStateManager(): dev.vmd1.gossip.features.hotspot.HotspotStateManager = hotspotStateManager

    fun ringManager(): dev.vmd1.gossip.features.find.RingManager = ringManager

    fun batterySyncManager(): dev.vmd1.gossip.features.battery.BatterySyncManager = batterySyncManager

    /** Exposed so the home screen can show a "your screen is being mirrored" indicator —
     *  see [dev.vmd1.gossip.features.screenmirror.ScreenMirrorState]'s own doc comment, which
     *  already anticipated this accessor ("exists purely so a future 'Mirroring active'
     *  indicator... has something to observe") but nothing had wired it up yet; found
     *  during this handoff's Phase 3 parity audit (`HANDOFF_ONBOARDING_AND_POLISH.md`) —
     *  the state was tracked correctly the whole time, just never surfaced anywhere. */
    fun screenMirrorState(): ScreenMirrorState = screenMirrorState

    /** Null until Shizuku's binder lifecycle initializes it in [onCreate] — practically
     *  always non-null by the time a bound client reads this, since binding itself is
     *  already async. Exposed so onboarding's hotspot-mechanism-test step (see
     *  `HANDOFF_ONBOARDING_AND_POLISH.md` Phase 2) can call [dev.vmd1.gossip.features.hotspot.
     *  TetherHelper.probeMechanisms] with the real, running instance instead of
     *  constructing a second one. */
    fun shizukuManager(): dev.vmd1.gossip.features.hotspot.ShizukuManager? = shizukuManager

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
        private const val ACTION_STOP_RING = "dev.vmd1.gossip.STOP_RING"
        private const val RING_CHANNEL_ID = "gossip_find_device"
        private const val RING_NOTIFICATION_ID = 1002
        private const val BATTERY_CHANNEL_ID = "gossip_battery_low"
        private const val BATTERY_NOTIFICATION_BASE = 6000
        /** Not private: [dev.vmd1.gossip.features.notifications.NotificationListenerImpl]
         *  needs this to specifically exclude the persistent "Gossip is running"
         *  notification from mirroring, without excluding every notification this
         *  app posts (e.g. a manual test notification). */
        const val NOTIFICATION_ID = 1001
        private const val FALLBACK_DIAL_INTERVAL_MS = 15_000L
        private const val DND_RESYNC_INTERVAL_MS = 60_000L
        private const val ROSTER_RESYNC_INTERVAL_MS = 300_000L
    }
}
