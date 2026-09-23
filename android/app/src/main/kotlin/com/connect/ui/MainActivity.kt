package com.connect.ui

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.util.Log
import android.net.Uri
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.lifecycle.lifecycleScope
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
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
import com.connect.crypto.TrustedDevice
import com.connect.crypto.TrustedDevicesStore
import com.connect.features.dnd.DndSyncManager
import com.connect.pairing.QRScanActivity
import com.connect.service.SyncForegroundService
import com.connect.transport.ConnectionState
import kotlinx.coroutines.launch

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

    /** Uris pulled from a share-sheet `ACTION_SEND`/`ACTION_SEND_MULTIPLE` intent
     *  before the foreground service (which owns [com.connect.features.filetransfer.FileTransferManager])
     *  has finished binding; flushed once it connects. */
    private val pendingShareUris = mutableListOf<Uri>()

    private val requestNotificationPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { /* no-op either way */ }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val serviceIntent = Intent(this, SyncForegroundService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(serviceIntent)
        } else {
            startService(serviceIntent)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            requestNotificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }

        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                boundService = (binder as? SyncForegroundService.LocalBinder)?.service()
                flushPendingShareUris()
            }

            override fun onServiceDisconnected(name: ComponentName?) {
                boundService = null
            }
        }
        serviceConnection = connection
        bindService(serviceIntent, connection, Context.BIND_AUTO_CREATE)

        handleShareIntent(intent)

        val trustedDevicesStore = TrustedDevicesStore.getInstance(applicationContext)

        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    ConnectHomeScreen(
                        connectionStateProvider = { boundService?.transportManager()?.connectionState },
                        trustedDevicesStore = trustedDevicesStore,
                        onPairNewDevice = {
                            startActivity(Intent(this@MainActivity, QRScanActivity::class.java))
                        },
                        isNotificationAccessGranted = { isNotificationListenerEnabled(this@MainActivity) },
                        onEnableNotificationAccess = {
                            startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                        },
                        onSendTestNotification = { postTestNotification() },
                        dndSyncManagerProvider = { boundService?.dndSyncManager() },
                        onRequestDndAccess = { dndSyncManager ->
                            startActivity(dndSyncManager.requestPolicyAccessIntent())
                        }
                    )
                }
            }
        }
    }

    override fun onDestroy() {
        serviceConnection?.let { runCatching { unbindService(it) } }
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleShareIntent(intent)
    }

    /** Extracts any `ACTION_SEND`/`ACTION_SEND_MULTIPLE` file Uris from [intent] ("Share
     *  to Mac"), queuing them for [FileTransferManager.sendFile] once the foreground
     *  service is bound (see [flushPendingShareUris]). */
    private fun handleShareIntent(intent: Intent?) {
        if (intent == null) return
        val uris: List<Uri> = when (intent.action) {
            Intent.ACTION_SEND -> {
                @Suppress("DEPRECATION")
                (intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri)?.let { listOf(it) } ?: emptyList()
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                @Suppress("DEPRECATION")
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM) ?: emptyList()
            }
            else -> emptyList()
        }
        if (uris.isEmpty()) return

        pendingShareUris.addAll(uris)
        flushPendingShareUris()
    }

    private fun flushPendingShareUris() {
        val service = boundService ?: return
        if (pendingShareUris.isEmpty()) return

        val toSend = pendingShareUris.toList()
        pendingShareUris.clear()
        lifecycleScope.launch {
            for (uri in toSend) {
                runCatching { service.fileTransferManager().sendFile(uri) }
                    .onFailure { Log.w("MainActivity", "Failed to send $uri", it) }
            }
        }
    }

    /** Posts a plain local notification (own dedicated channel — distinct from
     *  [SyncForegroundService]'s persistent low-priority sync channel) so the
     *  "Send Test Notification" button has something for
     *  [com.connect.features.notifications.NotificationListenerImpl] to actually
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
            .setContentTitle("Connect test notification")
            .setContentText("If this shows up on your Mac, mirroring is working.")
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
 *  for [com.connect.features.notifications.NotificationListenerImpl] to run. This
 *  permission has no runtime-dialog equivalent — it can only be granted from Settings. */
fun isNotificationListenerEnabled(context: Context): Boolean =
    NotificationManagerCompat.getEnabledListenerPackages(context).contains(context.packageName)

@Composable
fun ConnectHomeScreen(
    connectionStateProvider: () -> kotlinx.coroutines.flow.StateFlow<ConnectionState>?,
    trustedDevicesStore: TrustedDevicesStore,
    onPairNewDevice: () -> Unit,
    isNotificationAccessGranted: () -> Boolean = { true },
    onEnableNotificationAccess: () -> Unit = {},
    onSendTestNotification: () -> Unit = {},
    dndSyncManagerProvider: () -> DndSyncManager? = { null },
    onRequestDndAccess: (DndSyncManager) -> Unit = {}
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

    Scaffold { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Text("Connect", style = MaterialTheme.typography.headlineMedium)
            Text("Status: ${connectionState.name}")

            Button(onClick = onPairNewDevice) {
                Text("Pair New Device")
            }

            if (!notificationAccessGranted) {
                Text(
                    "Grant notification access so your Android notifications can be mirrored to your Mac.",
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
                Button(onClick = onSendTestNotification) {
                    Text("Send Test Notification")
                }
                Text(
                    "Posts a local notification — a quick way to confirm the mirroring " +
                        "pipeline reaches your Mac without waiting for a real app to notify you.",
                    style = MaterialTheme.typography.bodySmall
                )
            }

            if (!dndAccessGranted) {
                Text(
                    "To sync Do Not Disturb with your Mac, Connect needs notification " +
                        "policy access.",
                    style = MaterialTheme.typography.bodySmall
                )
                Button(onClick = {
                    dndSyncManagerProvider()?.let(onRequestDndAccess)
                }) {
                    Text("Grant DND Access")
                }
            }

            PairedDevicesScreen(
                devices = devices,
                onForget = { deviceId ->
                    trustedDevicesStore.revoke(deviceId)
                    devices = trustedDevicesStore.allDevices()
                },
                onSetFallbackHost = { deviceId, fallbackHost ->
                    trustedDevicesStore.setFallbackHost(deviceId, fallbackHost)
                    devices = trustedDevicesStore.allDevices()
                }
            )
        }
    }
}

@Preview(showBackground = true)
@Composable
private fun ConnectHomeScreenPreview() {
    MaterialTheme {
        Text("Connect")
    }
}
