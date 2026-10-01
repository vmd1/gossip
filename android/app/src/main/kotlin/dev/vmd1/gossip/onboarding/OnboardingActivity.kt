package dev.vmd1.gossip.onboarding

import android.Manifest
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import dev.vmd1.gossip.features.hotspot.HotspotToggleMechanism
import dev.vmd1.gossip.features.hotspot.ShizukuManager
import dev.vmd1.gossip.features.hotspot.TetherHelper
import dev.vmd1.gossip.features.proximity.LockOnLeaveManager
import dev.vmd1.gossip.pairing.QRScanActivity
import dev.vmd1.gossip.pairing.ShowQrActivity
import dev.vmd1.gossip.protocol.DeviceType
import dev.vmd1.gossip.protocol.detectDeviceType
import dev.vmd1.gossip.service.SyncForegroundService
import dev.vmd1.gossip.ui.MainActivity
import dev.vmd1.gossip.ui.isDeviceAdminActive
import dev.vmd1.gossip.ui.isNotificationListenerEnabled
import kotlinx.coroutines.launch

/**
 * First-run guided setup: "do you have another device?" → pairing, then a permissions
 * walkthrough, then a one-time hotspot-mechanism probe — chrome around the mechanisms
 * [MainActivity]'s `ConnectHomeScreen` already exposes as individual "Grant X" buttons, not
 * a rewrite of them (see `HANDOFF_ONBOARDING_AND_POLISH.md` Phase 2). Shown once
 * ([OnboardingPreferences.isCompleted]); re-enterable later via [MainActivity]'s own
 * "Run Setup Again" button, since permissions can be revoked out-of-band (Settings, an OS
 * update) and the hotspot mechanism that works can change across an OS upgrade.
 */
class OnboardingActivity : ComponentActivity() {

    private var boundService by androidx.compose.runtime.mutableStateOf<SyncForegroundService?>(null)
    private var serviceConnection: ServiceConnection? = null

    private var notificationPermissionGranted by androidx.compose.runtime.mutableStateOf(true)
    private val requestNotificationPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            notificationPermissionGranted = granted
        }

    private var bluetoothPermissionGranted by androidx.compose.runtime.mutableStateOf(false)
    private val requestBluetoothPermissions =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { results ->
            bluetoothPermissionGranted = results.values.all { it }
        }

    private var deviceAdminActive by androidx.compose.runtime.mutableStateOf(false)
    private val requestDeviceAdmin =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
            deviceAdminActive = isDeviceAdminActive(this)
        }

    private var notificationAccessGranted by androidx.compose.runtime.mutableStateOf(false)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val myDeviceType = detectDeviceType(applicationContext)
        deviceAdminActive = isDeviceAdminActive(this)
        notificationAccessGranted = isNotificationListenerEnabled(this)
        notificationPermissionGranted = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        bluetoothPermissionGranted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_ADVERTISE, Manifest.permission.BLUETOOTH_CONNECT)
                .all { ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED }
        } else {
            ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        }

        // MainActivity hands off to onboarding *before* it starts the sync service on a fresh
        // install, so start it here too — without it nothing listens or advertises on the network
        // (no mDNS registration, no server socket) and pairing from the onboarding screens fails
        // with "could not find <device> on the local network". Starting an already-running service
        // is a no-op.
        ContextCompat.startForegroundService(this, Intent(this, SyncForegroundService::class.java))

        // Same-process bind as MainActivity: gets a handle to the running service (ShizukuManager
        // for the hotspot probe step, etc.).
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                boundService = (binder as? SyncForegroundService.LocalBinder)?.service()
            }
            override fun onServiceDisconnected(name: ComponentName?) {
                boundService = null
            }
        }
        serviceConnection = connection
        bindService(Intent(this, SyncForegroundService::class.java), connection, Context.BIND_AUTO_CREATE)

        val prefs = OnboardingPreferences(applicationContext)

        setContent {
            dev.vmd1.gossip.ui.theme.ConnectTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    OnboardingFlow(
                        myDeviceType = myDeviceType,
                        onScanQr = { startActivity(Intent(this, QRScanActivity::class.java)) },
                        onShowQr = { startActivity(Intent(this, ShowQrActivity::class.java)) },
                        notificationAccessGranted = { notificationAccessGranted },
                        onEnableNotificationAccess = {
                            startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                        },
                        notificationPermissionGranted = { notificationPermissionGranted },
                        onRequestNotificationPermission = {
                            requestNotificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
                        },
                        dndAccessGranted = { boundService?.dndSyncManager()?.hasNotificationPolicyAccess() ?: false },
                        onRequestDndAccess = {
                            boundService?.dndSyncManager()?.let { startActivity(it.requestPolicyAccessIntent()) }
                        },
                        bluetoothPermissionGranted = { bluetoothPermissionGranted },
                        onRequestBluetoothPermission = {
                            val perms = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                                arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_ADVERTISE, Manifest.permission.BLUETOOTH_CONNECT)
                            } else {
                                arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
                            }
                            requestBluetoothPermissions.launch(perms)
                        },
                        deviceAdminActive = { deviceAdminActive },
                        onRequestDeviceAdmin = {
                            val intent = Intent(DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN).apply {
                                putExtra(DevicePolicyManager.EXTRA_DEVICE_ADMIN, LockOnLeaveManager.adminComponentName(this@OnboardingActivity))
                                putExtra(
                                    DevicePolicyManager.EXTRA_ADD_EXPLANATION,
                                    "Needed for Lock-on-Leave: lets Gossip lock this device's screen when a paired phone leaves Bluetooth range."
                                )
                            }
                            requestDeviceAdmin.launch(intent)
                        },
                        shizukuStateProvider = { boundService?.shizukuManager()?.state?.value },
                        onRequestShizuku = { boundService?.shizukuManager()?.requestPermission() },
                        onProbeHotspotMechanisms = { onComplete ->
                            lifecycleScope.launch {
                                val available = TetherHelper.probeMechanisms(applicationContext, boundService?.shizukuManager())
                                onComplete(available)
                            }
                        },
                        onPersistPreferredMechanism = { id -> prefs.preferredHotspotMechanismId = id },
                        onFinish = {
                            prefs.isCompleted = true
                            startActivity(Intent(this, MainActivity::class.java))
                            finish()
                        }
                    )
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        // Refresh the special-access permissions (no runtime-dialog result to observe)
        // whenever this screen resumes — same rationale as MainActivity's DisposableEffect:
        // these only change via a round-trip through Settings/another activity.
        notificationAccessGranted = isNotificationListenerEnabled(this)
        deviceAdminActive = isDeviceAdminActive(this)
    }

    override fun onDestroy() {
        serviceConnection?.let { runCatching { unbindService(it) } }
        super.onDestroy()
    }
}

private enum class OnboardingStep { OTHER_DEVICE, PERMISSIONS, HOTSPOT_TEST, DONE }

@Composable
private fun OnboardingFlow(
    myDeviceType: DeviceType,
    onScanQr: () -> Unit,
    onShowQr: () -> Unit,
    notificationAccessGranted: () -> Boolean,
    onEnableNotificationAccess: () -> Unit,
    notificationPermissionGranted: () -> Boolean,
    onRequestNotificationPermission: () -> Unit,
    dndAccessGranted: () -> Boolean,
    onRequestDndAccess: () -> Unit,
    bluetoothPermissionGranted: () -> Boolean,
    onRequestBluetoothPermission: () -> Unit,
    deviceAdminActive: () -> Boolean,
    onRequestDeviceAdmin: () -> Unit,
    shizukuStateProvider: () -> ShizukuManager.State?,
    onRequestShizuku: () -> Unit,
    onProbeHotspotMechanisms: ((List<HotspotToggleMechanism>) -> Unit) -> Unit,
    onPersistPreferredMechanism: (String?) -> Unit,
    onFinish: () -> Unit
) {
    var step by remember { mutableStateOf(OnboardingStep.OTHER_DEVICE) }
    val steps = OnboardingStep.entries

    Scaffold { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            LinearProgressIndicator(
                progress = { (steps.indexOf(step) + 1) / steps.size.toFloat() },
                modifier = Modifier.fillMaxWidth()
            )
            Text("Set up Gossip", style = MaterialTheme.typography.headlineMedium)

            // Cross-fade between steps rather than an instant cut, per `docs/design-system.md`'s
            // motion guidance (a real state change — the user just tapped Continue/a permission
            // changed — should read as the UI responding, not just re-rendering).
            //
            // The inner Column matters, not just style: AnimatedContent's content lambda isn't
            // a ColumnScope, but every step composable below (OtherDeviceStep, PermissionsStep,
            // etc.) emits several top-level children assuming Column semantics — without this
            // wrapper they stack on top of each other instead of flowing vertically (found live
            // on a real device: the wizard rendered as overlapping text/buttons).
            AnimatedContent(targetState = step, label = "onboarding_step") { targetStep ->
                Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    when (targetStep) {
                        OnboardingStep.OTHER_DEVICE -> OtherDeviceStep(
                            onScanQr = onScanQr,
                            onShowQr = onShowQr,
                            onContinue = { step = OnboardingStep.PERMISSIONS }
                        )
                        OnboardingStep.PERMISSIONS -> PermissionsStep(
                            myDeviceType = myDeviceType,
                            notificationAccessGranted = notificationAccessGranted(),
                            onEnableNotificationAccess = onEnableNotificationAccess,
                            notificationPermissionGranted = notificationPermissionGranted(),
                            onRequestNotificationPermission = onRequestNotificationPermission,
                            dndAccessGranted = dndAccessGranted(),
                            onRequestDndAccess = onRequestDndAccess,
                            bluetoothPermissionGranted = bluetoothPermissionGranted(),
                            onRequestBluetoothPermission = onRequestBluetoothPermission,
                            deviceAdminActive = deviceAdminActive(),
                            onRequestDeviceAdmin = onRequestDeviceAdmin,
                            myIsNonPhone = myDeviceType != DeviceType.ANDROID_PHONE,
                            shizukuState = shizukuStateProvider(),
                            onRequestShizuku = onRequestShizuku,
                            // Only a phone can ever provide Instant Hotspot (see
                            // docs/ble-hotspot-protocol.md's "GATT roles") — the
                            // hotspot-mechanism probe step is meaningless for a
                            // tablet/anything else, which never calls
                            // TetherHelper.setHotspotEnabled as a provider.
                            onContinue = {
                                step = if (myDeviceType == DeviceType.ANDROID_PHONE) {
                                    OnboardingStep.HOTSPOT_TEST
                                } else {
                                    OnboardingStep.DONE
                                }
                            }
                        )
                        OnboardingStep.HOTSPOT_TEST -> HotspotTestStep(
                            onProbe = onProbeHotspotMechanisms,
                            onPersistPreferredMechanism = onPersistPreferredMechanism,
                            onContinue = { step = OnboardingStep.DONE }
                        )
                        OnboardingStep.DONE -> DoneStep(onFinish = onFinish)
                    }
                }
            }
        }
    }
}

@Composable
private fun OtherDeviceStep(onScanQr: () -> Unit, onShowQr: () -> Unit, onContinue: () -> Unit) {
    Text("Do you have another device to connect to?", style = MaterialTheme.typography.titleMedium)
    Text(
        "Pair with your Mac or another Android device now, or skip and pair later from the " +
            "home screen.",
        style = MaterialTheme.typography.bodySmall
    )
    Button(onClick = onScanQr) { Text("Scan a QR Code") }
    OutlinedButton(onClick = onShowQr) { Text("Show My QR Code") }
    TextButton(onClick = onContinue) { Text("Skip for now") }
    Button(onClick = onContinue) { Text("Continue") }
}

@Composable
private fun PermissionsStep(
    myDeviceType: DeviceType,
    notificationAccessGranted: Boolean,
    onEnableNotificationAccess: () -> Unit,
    notificationPermissionGranted: Boolean,
    onRequestNotificationPermission: () -> Unit,
    dndAccessGranted: Boolean,
    onRequestDndAccess: () -> Unit,
    bluetoothPermissionGranted: Boolean,
    onRequestBluetoothPermission: () -> Unit,
    deviceAdminActive: Boolean,
    onRequestDeviceAdmin: () -> Unit,
    myIsNonPhone: Boolean,
    shizukuState: ShizukuManager.State?,
    onRequestShizuku: () -> Unit,
    onContinue: () -> Unit
) {
    Text("Grant a few permissions", style = MaterialTheme.typography.titleMedium)
    Text(
        "Each of these unlocks one feature. All are skippable — you can grant them later " +
            "from the home screen.",
        style = MaterialTheme.typography.bodySmall
    )

    if (!notificationPermissionGranted) {
        PermissionRow(
            "Post notifications",
            "Lets Gossip show its own sync-status notification, and — separately from " +
                "notification mirroring access below — lets a paired device's mirrored " +
                "notifications actually display here. Without this, mirrored notifications " +
                "are silently dropped by the system with no error.",
            onRequestNotificationPermission
        )
    }
    if (!notificationAccessGranted) {
        PermissionRow(
            "Notification mirroring",
            "Mirrors this phone's notifications to your paired devices.",
            onEnableNotificationAccess
        )
    }
    if (!dndAccessGranted) {
        PermissionRow(
            "Do Not Disturb sync",
            "Keeps Focus/DND state in sync across your devices.",
            onRequestDndAccess
        )
    }
    if (!bluetoothPermissionGranted) {
        PermissionRow(
            "Bluetooth",
            "Detects nearby trusted devices (e.g. for Lock-on-Leave).",
            onRequestBluetoothPermission
        )
    }
    if (myIsNonPhone && !deviceAdminActive) {
        PermissionRow(
            "Device admin",
            "Lets a paired phone lock this device when it leaves Bluetooth range.",
            onRequestDeviceAdmin
        )
    }
    if (shizukuState != null && shizukuState != ShizukuManager.State.CONNECTED) {
        PermissionRow(
            "Shizuku (optional)",
            "Enables Instant Hotspot and background clipboard sync on newer Android " +
                "versions. Skippable — everything else works without it.",
            onRequestShizuku
        )
    }

    Button(onClick = onContinue) { Text("Continue") }
}

@Composable
private fun PermissionRow(title: String, description: String, onGrant: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(title, style = MaterialTheme.typography.bodyMedium)
        Text(description, style = MaterialTheme.typography.bodySmall)
        Row { Button(onClick = onGrant) { Text("Grant") } }
    }
}

@Composable
private fun HotspotTestStep(
    onProbe: ((List<HotspotToggleMechanism>) -> Unit) -> Unit,
    onPersistPreferredMechanism: (String?) -> Unit,
    onContinue: () -> Unit
) {
    var probed by remember { mutableStateOf(false) }
    var available by remember { mutableStateOf<List<HotspotToggleMechanism>>(emptyList()) }

    Text("Test Instant Hotspot", style = MaterialTheme.typography.titleMedium)
    Text(
        "Gossip can turn on this phone's hotspot for a paired device automatically. " +
            "Which method works varies by phone and Android version — this checks once so " +
            "it doesn't have to guess later.",
        style = MaterialTheme.typography.bodySmall
    )

    if (!probed) {
        Button(onClick = {
            onProbe { result ->
                available = result
                onPersistPreferredMechanism(result.firstOrNull()?.id)
                probed = true
            }
        }) { Text("Test Hotspot Methods") }
        TextButton(onClick = onContinue) { Text("Skip for now") }
    } else {
        Text(
            if (available.isEmpty()) {
                "No hotspot method is available yet on this device — grant a permission " +
                    "above (or install Shizuku) and try again from Settings later."
            } else {
                "Found ${available.size} working method(s): ${available.joinToString { it.id }}. " +
                    "Gossip will use ${available.first().id} by default."
            },
            style = MaterialTheme.typography.bodySmall
        )
        Button(onClick = onContinue) { Text("Continue") }
    }
}

@Composable
private fun DoneStep(onFinish: () -> Unit) {
    Text("You're all set", style = MaterialTheme.typography.titleMedium)
    Text(
        "You can re-run this setup anytime from the home screen if you grant permissions " +
            "later or get a new device.",
        style = MaterialTheme.typography.bodySmall
    )
    Button(onClick = onFinish) { Text("Finish") }
}
