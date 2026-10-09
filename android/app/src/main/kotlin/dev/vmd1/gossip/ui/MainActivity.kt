package dev.vmd1.gossip.ui

import android.Manifest
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.background
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Settings
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import dev.vmd1.gossip.crypto.IdentityKeyStore
import dev.vmd1.gossip.crypto.TrustedDevice
import dev.vmd1.gossip.crypto.TrustedDevicesStore
import dev.vmd1.gossip.features.dnd.DndSyncManager
import dev.vmd1.gossip.features.proximity.LockOnLeaveManager
import dev.vmd1.gossip.onboarding.OnboardingActivity
import dev.vmd1.gossip.onboarding.OnboardingPreferences
import dev.vmd1.gossip.pairing.QRScanActivity
import dev.vmd1.gossip.pairing.ShowQrActivity
import dev.vmd1.gossip.protocol.DeviceType
import dev.vmd1.gossip.protocol.Envelope
import dev.vmd1.gossip.protocol.MessageType
import dev.vmd1.gossip.protocol.detectDeviceType
import dev.vmd1.gossip.service.SyncForegroundService
import dev.vmd1.gossip.transport.ConnectionState
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject

/**
 * Minimal launcher UI: connection status, a "Pair New Device" button, and the list of
 * currently trusted devices (see [PairedDevicesScreen]). Also starts/binds the
 * foreground sync service so the transport keeps running once the app is opened.
 */
class MainActivity : ComponentActivity() {

    /** A plain `var` here would never trigger recomposition when the async service
     *  bind completes: `connectionStateProvider`/etc. below are plain lambdas whose
     *  body only re-runs when something they read is observed Compose state, and a
     *  raw property mutation outside Compose's snapshot system doesn't count. That
     *  left every screen permanently showing whatever it captured at first
     *  composition (near-certainly `null`/disconnected, since `bindService` is
     *  async and its callback fires after `setContent` has already composed once) —
     *  this is why the UI could show "disconnected" forever even once the real
     *  transport connected. Compose state fixes it at the source. */
    private var boundService by androidx.compose.runtime.mutableStateOf<SyncForegroundService?>(null)
    private var serviceConnection: ServiceConnection? = null

    private val requestNotificationPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            notificationPermissionGranted = granted
        }

    /** Gates whether *any* local notification this app posts actually shows — both its own
     *  sync-status notification and, less obviously, a peer device's mirrored notifications
     *  (see `NotificationMirrorReceiver.handlePosted`'s `NotificationManagerCompat.notify`
     *  call, which silently no-ops without this, same failure mode Mac's own
     *  `notificationsDisabledRow` was built to warn about for its single unified permission
     *  — Android splits this from *listener* access, which only gates detecting this
     *  device's own notifications to mirror *out*). Found missing a persistent home-screen
     *  warning during this handoff's Phase 3 parity audit
     *  (`HANDOFF_ONBOARDING_AND_POLISH.md`) — previously only requested once at launch with
     *  no ongoing indication if denied (or later revoked in Settings). */
    private var notificationPermissionGranted by androidx.compose.runtime.mutableStateOf(true)

    private val requestBluetoothPermissions =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { results ->
            if (results.values.all { it }) {
                boundService?.bleProximityMonitor()?.let { monitor ->
                    monitor.rebuildFingerprintMap()
                    monitor.start()
                }
            }
            bluetoothPermissionGranted = results.values.all { it }
        }

    private var bluetoothPermissionGranted by androidx.compose.runtime.mutableStateOf(false)

    private var deviceAdminActive by androidx.compose.runtime.mutableStateOf(false)

    private val requestDeviceAdmin =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
            deviceAdminActive = isDeviceAdminActive(this)
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        if (!OnboardingPreferences(applicationContext).isCompleted) {
            startActivity(Intent(this, OnboardingActivity::class.java))
            finish()
            return
        }

        val serviceIntent = Intent(this, SyncForegroundService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(serviceIntent)
        } else {
            startService(serviceIntent)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            notificationPermissionGranted = ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED
            if (!notificationPermissionGranted) {
                requestNotificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
            }
        }
        // Pre-Tiramisu: POST_NOTIFICATIONS doesn't exist as a runtime permission — posting
        // is always allowed (subject only to the user's OS-level notification settings,
        // which this app has no API to query) — notificationPermissionGranted's `true`
        // default is correct as-is here.

        // BLE proximity (see docs/ble-proximity-protocol.md) needs BLUETOOTH_SCAN or
        // BLUETOOTH_ADVERTISE depending on this device's role, both runtime-dangerous
        // permissions on API 31+. Request both regardless of role — harmless to hold
        // the one this device's role doesn't use, and simpler than branching here.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val bluetoothPermissions = arrayOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_ADVERTISE,
                Manifest.permission.BLUETOOTH_CONNECT
            )
            bluetoothPermissionGranted = bluetoothPermissions.all {
                ContextCompat.checkSelfPermission(this, it) == android.content.pm.PackageManager.PERMISSION_GRANTED
            }
            if (!bluetoothPermissionGranted) {
                requestBluetoothPermissions.launch(bluetoothPermissions)
            }
        } else {
            bluetoothPermissionGranted = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED
        }

        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                boundService = (binder as? SyncForegroundService.LocalBinder)?.service()
            }

            override fun onServiceDisconnected(name: ComponentName?) {
                boundService = null
            }
        }
        serviceConnection = connection
        bindService(serviceIntent, connection, Context.BIND_AUTO_CREATE)

        val trustedDevicesStore = TrustedDevicesStore.getInstance(applicationContext)
        val myDeviceType = detectDeviceType(applicationContext)
        deviceAdminActive = isDeviceAdminActive(this)

        setContent {
            dev.vmd1.gossip.ui.theme.ConnectTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    ConnectHomeScreen(
                        connectionStateProvider = { boundService?.transportManager()?.connectionState },
                        trustedDevicesStore = trustedDevicesStore,
                        onPairNewDevice = {
                            startActivity(Intent(this@MainActivity, QRScanActivity::class.java))
                        },
                        onShowQrToPair = {
                            startActivity(Intent(this@MainActivity, ShowQrActivity::class.java))
                        },
                        onRunSetupAgain = {
                            startActivity(Intent(this@MainActivity, OnboardingActivity::class.java))
                        },
                        isNotificationAccessGranted = { isNotificationListenerEnabled(this@MainActivity) },
                        onEnableNotificationAccess = {
                            startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                        },
                        onSendTestNotification = { postTestNotification() },
                        notificationPermissionGranted = { notificationPermissionGranted },
                        onRequestNotificationPermission = {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                                requestNotificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
                            }
                        },
                        dndSyncManagerProvider = { boundService?.dndSyncManager() },
                        onRequestDndAccess = { dndSyncManager ->
                            startActivity(dndSyncManager.requestPolicyAccessIntent())
                        },
                        rosterGossipManagerProvider = { boundService?.rosterGossipManager() },
                        bluetoothPermissionGranted = { bluetoothPermissionGranted },
                        onRequestBluetoothPermission = {
                            val perms = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                                arrayOf(
                                    Manifest.permission.BLUETOOTH_SCAN,
                                    Manifest.permission.BLUETOOTH_ADVERTISE,
                                    Manifest.permission.BLUETOOTH_CONNECT
                                )
                            } else {
                                arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
                            }
                            requestBluetoothPermissions.launch(perms)
                        },
                        nearbyDeviceIdsProvider = { boundService?.bleProximityMonitor()?.nearbyDeviceIds },
                        myDeviceType = myDeviceType,
                        deviceAdminActive = { deviceAdminActive },
                        onRequestDeviceAdmin = {
                            val intent = Intent(DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN).apply {
                                putExtra(DevicePolicyManager.EXTRA_DEVICE_ADMIN, LockOnLeaveManager.adminComponentName(this@MainActivity))
                                putExtra(
                                    DevicePolicyManager.EXTRA_ADD_EXPLANATION,
                                    "Needed for Lock-on-Leave: lets Gossip lock this device's screen when a paired phone leaves Bluetooth range."
                                )
                            }
                            requestDeviceAdmin.launch(intent)
                        },
                        onSetLockOnLeave = { deviceId, enabled ->
                            trustedDevicesStore.setLockOnLeaveEnabled(deviceId, enabled)
                            val transport = boundService?.transportManager()
                            if (transport != null) {
                                val envelope = Envelope(
                                    type = MessageType.LOCK_ON_LEAVE_CONFIG,
                                    senderId = IdentityKeyStore.getInstance(applicationContext).deviceId,
                                    recipientId = deviceId,
                                    payload = buildJsonObject { put("enabled", JsonPrimitive(enabled)) }
                                )
                                lifecycleScope.launch {
                                    runCatching { transport.send(envelope) }
                                }
                            }
                        },
                        provideHotspotEnabledProvider = { OnboardingPreferences(applicationContext).provideHotspotEnabled },
                        onSetProvideHotspotEnabled = { enabled ->
                            OnboardingPreferences(applicationContext).provideHotspotEnabled = enabled
                            boundService?.bleProximityMonitor()?.setHotspotAvailable(
                                enabled && dev.vmd1.gossip.features.settings.FeatureSettings.getInstance(applicationContext)
                                    .isEnabled(dev.vmd1.gossip.features.settings.Feature.HOTSPOT)
                            )
                        },
                        hotspotStatesProvider = { boundService?.hotspotStateManager()?.hotspotStateBySenderId },
                        bleHotspotOnStatesProvider = { boundService?.bleProximityMonitor()?.hotspotOnByDeviceId },
                        onRequestHotspot = { deviceId, enable -> requestHotspot(deviceId, enable) },
                        hotspotOverrides = hotspotOverrides,
                        directDeviceIdsProvider = { boundService?.transportManager()?.connectedDeviceIds },
                        meshDeviceIdsProvider = { boundService?.transportManager()?.meshReachableDeviceIds },
                        relayedDeviceIdsProvider = { boundService?.transportManager()?.relayedDeviceIds },
                        relayStatusProvider = { boundService?.transportManager()?.let { t -> RelayUiState(t.relayStatus, t.relayIdle, t.relayErrorCode) } },
                        batteryStatesProvider = { boundService?.batterySyncManager()?.batteryBySenderId },
                        ringingPeersProvider = { boundService?.ringManager()?.ringingPeers },
                        onToggleRing = { deviceId -> boundService?.ringManager()?.toggleRing(deviceId) }
                    )
                }
            }
        }
    }

    override fun onDestroy() {
        serviceConnection?.let { runCatching { unbindService(it) } }
        activeHotspotConnection?.let { dev.vmd1.gossip.features.hotspot.HotspotAutoConnect.disconnect(this, it) }
        super.onDestroy()
    }

    /** Network callback for a Wi-Fi connection this device joined via
     *  [dev.vmd1.gossip.features.hotspot.HotspotAutoConnect] — kept so it can be released
     *  ([dev.vmd1.gossip.features.hotspot.HotspotAutoConnect.disconnect]) once this device
     *  no longer needs it, rather than holding the connection open forever. Only one at
     *  a time, matching [requestHotspot] only ever having one request in flight. */
    /** The hotspot state the phone itself just confirmed over GATT, per device (state, time ms). The BLE
     *  advertisement bit and the mesh report both lag a real toggle by several seconds, so the icon
     *  trusts this until they catch up — see [PairedDevicesScreen]. */
    private val hotspotOverrides = androidx.compose.runtime.mutableStateMapOf<String, Pair<Boolean, Long>>()

    private var activeHotspotConnection: android.net.ConnectivityManager.NetworkCallback? = null

    /** Sends a signed `hotspot.toggle_request` to [deviceId] over BLE GATT, and on a
     *  successful response carrying credentials, joins that network automatically. See
     *  `docs/ble-hotspot-protocol.md`. Feedback is a plain `Toast` — this is the
     *  feature's first cut of UI, not a polished flow (no persistent "connecting..."
     *  indicator, no retry). */
    private fun requestHotspot(deviceId: String, enable: Boolean) {
        val bluetoothDevice = boundService?.bleProximityMonitor()?.bluetoothDevice(deviceId)
        if (bluetoothDevice == null) {
            android.widget.Toast.makeText(this, "Device is no longer nearby", android.widget.Toast.LENGTH_SHORT).show()
            return
        }
        val identity = IdentityKeyStore.getInstance(applicationContext)
        val trustedDevicesStore = TrustedDevicesStore.getInstance(applicationContext)
        val client = dev.vmd1.gossip.features.hotspot.HotspotGattClient(applicationContext, identity, trustedDevicesStore)
        android.widget.Toast.makeText(
            this,
            if (enable) "Requesting hotspot…" else "Requesting hotspot off…",
            android.widget.Toast.LENGTH_SHORT
        ).show()
        lifecycleScope.launch {
            when (val result = client.requestToggle(bluetoothDevice, deviceId, enable = enable)) {
                is dev.vmd1.gossip.features.hotspot.HotspotGattClient.Result.Failed -> {
                    android.widget.Toast.makeText(this@MainActivity, "Hotspot request failed: ${result.reason}", android.widget.Toast.LENGTH_LONG).show()
                }
                is dev.vmd1.gossip.features.hotspot.HotspotGattClient.Result.Success -> {
                    hotspotOverrides[deviceId] = result.enabled to System.currentTimeMillis()
                    if (!enable) {
                        val message = if (!result.enabled) "Hotspot turned off" else "That device kept its hotspot on"
                        android.widget.Toast.makeText(this@MainActivity, message, android.widget.Toast.LENGTH_SHORT).show()
                        return@launch
                    }
                    if (!result.enabled) {
                        android.widget.Toast.makeText(this@MainActivity, "That device declined the hotspot request", android.widget.Toast.LENGTH_LONG).show()
                        return@launch
                    }
                    val ssid = result.ssid
                    val passphrase = result.passphrase
                    if (ssid == null || passphrase == null) {
                        android.widget.Toast.makeText(
                            this@MainActivity,
                            "Hotspot is on — connect manually (credentials weren't available to auto-connect)",
                            android.widget.Toast.LENGTH_LONG
                        ).show()
                        return@launch
                    }
                    activeHotspotConnection?.let { dev.vmd1.gossip.features.hotspot.HotspotAutoConnect.disconnect(this@MainActivity, it) }
                    activeHotspotConnection = dev.vmd1.gossip.features.hotspot.HotspotAutoConnect.connect(applicationContext, ssid, passphrase) { connected ->
                        val message = if (connected) "Connected to $ssid" else "Could not auto-connect to $ssid — connect manually"
                        android.widget.Toast.makeText(this@MainActivity, message, android.widget.Toast.LENGTH_LONG).show()
                    }
                }
            }
        }
    }

    /** Posts a plain local notification (own dedicated channel — distinct from
     *  [SyncForegroundService]'s persistent low-priority sync channel) so the
     *  "Send Test Notification" button has something for
     *  [dev.vmd1.gossip.features.notifications.NotificationListenerImpl] to actually
     *  pick up and mirror, without needing a real third-party app to trigger one.
     *  Uses a fixed notification ID so repeated taps replace rather than stack. */
    private fun postTestNotification() {
        val channelId = "connect_test"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(android.app.NotificationManager::class.java)
            val channel = android.app.NotificationChannel(
                channelId,
                "Test notifications",
                android.app.NotificationManager.IMPORTANCE_DEFAULT
            )
            manager.createNotificationChannel(channel)
        }
        val notification = androidx.core.app.NotificationCompat.Builder(this, channelId)
            .setContentTitle("Gossip test notification")
            .setContentText("If this shows up on your paired devices, mirroring is working.")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setPriority(androidx.core.app.NotificationCompat.PRIORITY_DEFAULT)
            .setAutoCancel(true)
            .build()
        NotificationManagerCompat.from(this).notify(TEST_NOTIFICATION_ID, notification)
    }

    companion object {
        private const val TEST_NOTIFICATION_ID = 2001
    }
}

/** Whether the user has granted this app "Notification access" special access, required
 *  for [dev.vmd1.gossip.features.notifications.NotificationListenerImpl] to run. This
 *  permission has no runtime-dialog equivalent — it can only be granted from Settings. */
fun isNotificationListenerEnabled(context: Context): Boolean =
    NotificationManagerCompat.getEnabledListenerPackages(context).contains(context.packageName)

/** Whether this app is an active device admin, required for [DevicePolicyManager.lockNow]
 *  in Lock-on-Leave (tablet side — see [LockOnLeaveManager]). Also has no runtime-dialog
 *  equivalent — only the dedicated `ACTION_ADD_DEVICE_ADMIN` system screen grants it. */
fun isDeviceAdminActive(context: Context): Boolean {
    val dpm = context.getSystemService(DevicePolicyManager::class.java)
    return dpm?.isAdminActive(LockOnLeaveManager.adminComponentName(context)) == true
}

@Composable
fun ConnectHomeScreen(
    connectionStateProvider: () -> kotlinx.coroutines.flow.StateFlow<ConnectionState>?,
    trustedDevicesStore: TrustedDevicesStore,
    onPairNewDevice: () -> Unit,
    onShowQrToPair: () -> Unit = {},
    onRunSetupAgain: () -> Unit = {},
    isNotificationAccessGranted: () -> Boolean = { true },
    onEnableNotificationAccess: () -> Unit = {},
    onSendTestNotification: () -> Unit = {},
    notificationPermissionGranted: () -> Boolean = { true },
    onRequestNotificationPermission: () -> Unit = {},
    dndSyncManagerProvider: () -> DndSyncManager? = { null },
    onRequestDndAccess: (DndSyncManager) -> Unit = {},
    rosterGossipManagerProvider: () -> dev.vmd1.gossip.features.trust.RosterGossipManager? = { null },
    bluetoothPermissionGranted: () -> Boolean = { true },
    onRequestBluetoothPermission: () -> Unit = {},
    nearbyDeviceIdsProvider: () -> kotlinx.coroutines.flow.StateFlow<Set<String>>? = { null },
    myDeviceType: DeviceType = DeviceType.ANDROID_PHONE,
    deviceAdminActive: () -> Boolean = { true },
    onRequestDeviceAdmin: () -> Unit = {},
    onSetLockOnLeave: (deviceId: String, enabled: Boolean) -> Unit = { _, _ -> },
    provideHotspotEnabledProvider: () -> Boolean = { false },
    onSetProvideHotspotEnabled: (Boolean) -> Unit = {},
    hotspotStatesProvider: () -> kotlinx.coroutines.flow.StateFlow<Map<String, dev.vmd1.gossip.features.hotspot.HotspotState>>? = { null },
    bleHotspotOnStatesProvider: () -> kotlinx.coroutines.flow.StateFlow<Map<String, Boolean>>? = { null },
    onRequestHotspot: (deviceId: String, enable: Boolean) -> Unit = { _, _ -> },
    hotspotOverrides: Map<String, Pair<Boolean, Long>> = emptyMap(),
    directDeviceIdsProvider: () -> kotlinx.coroutines.flow.StateFlow<Set<String>>? = { null },
    meshDeviceIdsProvider: () -> kotlinx.coroutines.flow.StateFlow<Set<String>>? = { null },
    relayedDeviceIdsProvider: () -> kotlinx.coroutines.flow.StateFlow<Set<String>>? = { null },
    relayStatusProvider: () -> RelayUiState? = { null },
    batteryStatesProvider: () -> kotlinx.coroutines.flow.StateFlow<Map<String, dev.vmd1.gossip.features.battery.BatteryState>>? = { null },
    ringingPeersProvider: () -> kotlinx.coroutines.flow.StateFlow<Set<String>>? = { null },
    onToggleRing: (deviceId: String) -> Unit = {}
) {
    var devices by remember { mutableStateOf<List<TrustedDevice>>(trustedDevicesStore.allDevices()) }
    val stateFlow = connectionStateProvider()
    val connectionState by (stateFlow?.collectAsState() ?: remember { mutableStateOf(ConnectionState.DISCONNECTED) })
    var notificationAccessGranted by remember { mutableStateOf(isNotificationAccessGranted()) }

    // The service binds asynchronously and notification policy access can only change by
    // the user leaving for Settings and coming back, so re-check on every recomposition
    // pass through this lifecycle owner's RESUMED state (covers both cases without
    // needing a dedicated observer). Also re-reads the trusted-devices list here: pairing
    // happens in QRScanActivity (a separate Activity, whose PairingViewModel calls
    // `trustedDevicesStore.addDevice` directly), and MainActivity's Compose tree survives
    // across that round-trip without recomposing on its own — `devices` was otherwise a
    // one-shot snapshot from whenever this screen first composed, so a newly-paired device
    // never appeared until the app was force-restarted.
    val lifecycleOwner = androidx.compose.ui.platform.LocalLifecycleOwner.current
    var dndAccessGranted by remember { mutableStateOf(false) }
    androidx.compose.runtime.DisposableEffect(lifecycleOwner) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (event == androidx.lifecycle.Lifecycle.Event.ON_RESUME) {
                dndAccessGranted = dndSyncManagerProvider()?.hasNotificationPolicyAccess() ?: false
                devices = trustedDevicesStore.allDevices()
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    // Everything that isn't the status + paired devices lives under Settings, a menu of sub-pages shown in
    // place of the home screen. `null` = the home screen; Back steps up one level (see SettingsPage.parent).
    var settingsPage by remember { mutableStateOf<SettingsPage?>(null) }
    val isPhone = myDeviceType == DeviceType.ANDROID_PHONE
    settingsPage?.let { page ->
        androidx.activity.compose.BackHandler { settingsPage = page.parent }
        val featureSettings = dev.vmd1.gossip.features.settings.FeatureSettings.getInstance(androidx.compose.ui.platform.LocalContext.current)
        val forwardSettings = dev.vmd1.gossip.features.notifications.NotificationForwardSettings.getInstance(
            androidx.compose.ui.platform.LocalContext.current
        )
        when (page) {
            SettingsPage.ROOT -> SettingsPageScaffold("Settings", onBack = { settingsPage = null }) {
                SettingsMenuRow("Devices & pairing", "Pair a device, show your QR code, run setup again") {
                    settingsPage = SettingsPage.DEVICES
                }
                if (isPhone) {
                    SettingsMenuRow("Notifications", "Notification access and which apps are forwarded") {
                        settingsPage = SettingsPage.NOTIFICATIONS
                    }
                }
                SettingsMenuRow("Features", "Turn features on or off on this device") { settingsPage = SettingsPage.FEATURES }
                SettingsMenuRow("Relay", "Stay connected when your devices are not on the same network") { settingsPage = SettingsPage.RELAY }
                if (isPhone) {
                    SettingsMenuRow("Instant Hotspot", "Let your other devices use this phone's hotspot") {
                        settingsPage = SettingsPage.HOTSPOT
                    }
                }
                SettingsMenuRow("Permissions", "Notifications, Do Not Disturb, Bluetooth and more") {
                    settingsPage = SettingsPage.PERMISSIONS
                }
                // "Gossip 17" for a release build, "Gossip dev" for a local one (the release workflow stamps the number).
                Text(
                    "Gossip ${dev.vmd1.gossip.BuildConfig.VERSION_NAME}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.fillMaxWidth().padding(top = 16.dp),
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center
                )
            }

            SettingsPage.DEVICES -> SettingsPageScaffold("Devices & pairing", onBack = { settingsPage = page.parent }) {
                Button(onClick = onPairNewDevice) { Text("Pair New Device") }
                Button(onClick = onShowQrToPair) { Text("Show QR to Pair") }
                androidx.compose.material3.TextButton(onClick = onRunSetupAgain) { Text("Run Setup Again") }
            }

            SettingsPage.NOTIFICATIONS -> SettingsPageScaffold("Notifications", onBack = { settingsPage = page.parent }) {
                if (!notificationAccessGranted) {
                    Text(
                        "Grant notification access so your Android notifications can be mirrored to your paired devices.",
                        style = MaterialTheme.typography.bodySmall
                    )
                    Button(onClick = {
                        onEnableNotificationAccess()
                        notificationAccessGranted = isNotificationAccessGranted()
                    }) {
                        Text("Enable Notification Mirroring")
                    }
                } else {
                    Text("Notification mirroring is enabled.", style = MaterialTheme.typography.bodySmall)
                    val blockedCount by forwardSettings.blocked.collectAsState()
                    SettingsMenuRow(
                        "Apps",
                        if (blockedCount.isEmpty()) "All apps are forwarded" else "${blockedCount.size} apps are not forwarded"
                    ) { settingsPage = SettingsPage.NOTIFICATION_APPS }
                    Button(onClick = onSendTestNotification) { Text("Send Test Notification") }
                    Text(
                        "Posts a local notification — a quick way to confirm the mirroring " +
                            "pipeline reaches your paired devices without waiting for a real app to notify you.",
                        style = MaterialTheme.typography.bodySmall
                    )
                }
            }

            SettingsPage.NOTIFICATION_APPS -> SettingsPageScaffold("Forwarded apps", onBack = { settingsPage = page.parent }, scroll = false) {
                NotificationAppsContent()
            }

            SettingsPage.FEATURES -> SettingsPageScaffold("Features", onBack = { settingsPage = page.parent }) {
                FeatureTogglesContent(featureSettings)
            }

            SettingsPage.RELAY -> SettingsPageScaffold("Relay", onBack = { settingsPage = page.parent }) {
                RelaySettingsContent(
                    settings = dev.vmd1.gossip.transport.RelaySettings.getInstance(androidx.compose.ui.platform.LocalContext.current),
                    state = relayStatusProvider()
                )
            }

            SettingsPage.HOTSPOT -> SettingsPageScaffold("Instant Hotspot", onBack = { settingsPage = page.parent }) {
                var provideHotspotEnabled by remember { mutableStateOf(provideHotspotEnabledProvider()) }
                androidx.compose.foundation.layout.Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = androidx.compose.ui.Alignment.CenterVertically
                ) {
                    Column(modifier = Modifier.weight(1f).padding(end = 12.dp)) {
                        Text("Provide Instant Hotspot", style = MaterialTheme.typography.bodyLarge)
                        Text(
                            "Let nearby trusted devices with no internet request a hotspot from " +
                                "this phone. Off by default — uses cellular data and battery.",
                            style = MaterialTheme.typography.bodySmall
                        )
                    }
                    androidx.compose.material3.Switch(
                        checked = provideHotspotEnabled,
                        onCheckedChange = {
                            provideHotspotEnabled = it
                            onSetProvideHotspotEnabled(it)
                        }
                    )
                }
            }

            SettingsPage.PERMISSIONS -> SettingsPageScaffold("Permissions", onBack = { settingsPage = page.parent }) {
                val needsDeviceAdmin = !isPhone && !deviceAdminActive()
                if (notificationPermissionGranted() && dndAccessGranted && bluetoothPermissionGranted() && !needsDeviceAdmin) {
                    Text("All permissions are granted.", style = MaterialTheme.typography.bodyMedium)
                }
                if (!notificationPermissionGranted()) {
                    Surface(
                        modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(8.dp),
                        color = MaterialTheme.colorScheme.errorContainer
                    ) {
                        Column(
                            modifier = Modifier.fillMaxWidth().padding(12.dp),
                            verticalArrangement = Arrangement.spacedBy(4.dp)
                        ) {
                            Text(
                                "Notifications permission is off — a paired device's mirrored " +
                                    "notifications will be silently dropped, with no error shown " +
                                    "anywhere.",
                                color = MaterialTheme.colorScheme.onErrorContainer,
                                style = MaterialTheme.typography.bodySmall
                            )
                            Button(onClick = onRequestNotificationPermission) {
                                Text("Grant Notifications Permission")
                            }
                        }
                    }
                }
                if (!dndAccessGranted) {
                    Text(
                        "To sync Do Not Disturb with your paired devices, Gossip needs notification " +
                            "policy access.",
                        style = MaterialTheme.typography.bodySmall
                    )
                    Button(onClick = { dndSyncManagerProvider()?.let(onRequestDndAccess) }) {
                        Text("Grant DND Access")
                    }
                }
                if (!bluetoothPermissionGranted()) {
                    Text(
                        "To detect nearby trusted devices over Bluetooth (for features like " +
                            "locking a paired Mac or tablet when your phone leaves range), Gossip needs " +
                            "Bluetooth permission.",
                        style = MaterialTheme.typography.bodySmall
                    )
                    Button(onClick = onRequestBluetoothPermission) { Text("Grant Bluetooth Permission") }
                }
                if (needsDeviceAdmin) {
                    Text(
                        "To let a paired phone lock this device when it leaves Bluetooth range " +
                            "(Lock-on-Leave), Gossip needs device admin access.",
                        style = MaterialTheme.typography.bodySmall
                    )
                    Button(onClick = onRequestDeviceAdmin) { Text("Grant Device Admin") }
                }
            }
        }
        return
    }

    Scaffold { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            androidx.compose.foundation.layout.Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = androidx.compose.ui.Alignment.CenterVertically
            ) {
                Text("Gossip", style = MaterialTheme.typography.headlineMedium)
                androidx.compose.material3.IconButton(onClick = { settingsPage = SettingsPage.ROOT }) {
                    androidx.compose.material3.Icon(
                        Icons.Default.Settings,
                        contentDescription = "Settings"
                    )
                }
            }
            ConnectionStatusCard(connectionState)

            val nearbyDeviceIds by (nearbyDeviceIdsProvider()?.collectAsState() ?: remember { mutableStateOf(emptySet<String>()) })
            val hotspotStates by (hotspotStatesProvider()?.collectAsState() ?: remember { mutableStateOf(emptyMap<String, dev.vmd1.gossip.features.hotspot.HotspotState>()) })
            val bleHotspotOnStates by (bleHotspotOnStatesProvider()?.collectAsState() ?: remember { mutableStateOf(emptyMap<String, Boolean>()) })
            val ringingPeers by (ringingPeersProvider()?.collectAsState() ?: remember { mutableStateOf(emptySet<String>()) })
            val directDeviceIds by (directDeviceIdsProvider()?.collectAsState() ?: remember { mutableStateOf(emptySet<String>()) })
            val meshDeviceIds by (meshDeviceIdsProvider()?.collectAsState() ?: remember { mutableStateOf(emptySet<String>()) })
            val relayedDeviceIds by (relayedDeviceIdsProvider()?.collectAsState() ?: remember { mutableStateOf(emptySet<String>()) })
            val batteryStates by (batteryStatesProvider()?.collectAsState() ?: remember { mutableStateOf(emptyMap<String, dev.vmd1.gossip.features.battery.BatteryState>()) })

            val toastContext = androidx.compose.ui.platform.LocalContext.current
            PairedDevicesScreen(
                devices = devices,
                nearbyDeviceIds = nearbyDeviceIds,
                myDeviceType = myDeviceType,
                onSetLockOnLeave = onSetLockOnLeave,
                hotspotStates = hotspotStates,
                bleHotspotOnStates = bleHotspotOnStates,
                onRequestHotspot = onRequestHotspot,
                hotspotOverrides = hotspotOverrides,
                directDeviceIds = directDeviceIds,
                meshDeviceIds = meshDeviceIds,
                relayedDeviceIds = relayedDeviceIds,
                batteryStates = batteryStates,
                ringingPeers = ringingPeers,
                onToggleRing = onToggleRing,
                onForget = { deviceId ->
                    // Prefer the roster-gossip path (revokes locally *and* broadcasts
                    // `trust.revoke` so the rest of the mesh drops trust too) — falls
                    // back to a local-only revoke if the service isn't bound yet.
                    val roster = rosterGossipManagerProvider()
                    if (roster != null) {
                        roster.revoke(deviceId)
                    } else {
                        trustedDevicesStore.revoke(deviceId)
                    }
                    devices = trustedDevicesStore.allDevices()
                },
                onSetFallbackHost = { deviceId, fallbackHost ->
                    if (!trustedDevicesStore.setFallbackHost(deviceId, fallbackHost)) {
                        android.widget.Toast.makeText(toastContext, "That isn't a valid IP address or hostname", android.widget.Toast.LENGTH_SHORT).show()
                    }
                    devices = trustedDevicesStore.allDevices()
                }
            )
        }
    }
}

/** Rounded status card: a coloured dot, a plain-language state and a one-line explanation. */
@Composable
private fun ConnectionStatusCard(state: ConnectionState) {
    val (dot, title, detail) = when (state) {
        ConnectionState.CONNECTED -> Triple(androidx.compose.ui.graphics.Color(0xFF34C759), "Connected", "Syncing with your paired devices")
        ConnectionState.HANDSHAKING -> Triple(androidx.compose.ui.graphics.Color(0xFFFF9500), "Connecting…", "Securing the connection")
        ConnectionState.DISCOVERING -> Triple(androidx.compose.ui.graphics.Color(0xFFFFCC00), "Searching…", "Looking for your paired devices")
        ConnectionState.DISCONNECTED -> Triple(androidx.compose.ui.graphics.Color(0xFF8E8E93), "Disconnected", "Not connected to any device")
    }
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surfaceVariant
    ) {
        androidx.compose.foundation.layout.Row(
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 14.dp),
            verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            androidx.compose.foundation.layout.Box(
                modifier = Modifier
                    .size(12.dp)
                    .background(dot, androidx.compose.foundation.shape.CircleShape)
            )
            Column {
                Text(title, style = MaterialTheme.typography.titleMedium)
                Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Preview(showBackground = true)
@Composable
private fun ConnectHomeScreenPreview() {
    MaterialTheme {
        Text("Gossip")
    }
}
