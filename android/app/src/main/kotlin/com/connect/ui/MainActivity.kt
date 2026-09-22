package com.connect.ui

import android.Manifest
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

/**
 * Minimal launcher UI: connection status, a "Pair New Device" button, and the list of
 * currently trusted devices (see [PairedDevicesScreen]). Also starts/binds the
 * foreground sync service so the transport keeps running once the app is opened.
 */
class MainActivity : ComponentActivity() {

    private var boundService: SyncForegroundService? = null
    private var serviceConnection: ServiceConnection? = null

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
            }

            override fun onServiceDisconnected(name: ComponentName?) {
                boundService = null
            }
        }
        serviceConnection = connection
        bindService(serviceIntent, connection, Context.BIND_AUTO_CREATE)

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
    // needing a dedicated observer).
    val lifecycleOwner = androidx.compose.ui.platform.LocalLifecycleOwner.current
    var dndAccessGranted by remember { mutableStateOf(false) }
    androidx.compose.runtime.DisposableEffect(lifecycleOwner) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (event == androidx.lifecycle.Lifecycle.Event.ON_RESUME) {
                dndAccessGranted = dndSyncManagerProvider()?.hasNotificationPolicyAccess() ?: false
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
