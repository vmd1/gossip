package dev.vmd1.gossip.pairing

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.IBinder
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.unit.dp
import dev.vmd1.gossip.crypto.IdentityKeyStore
import dev.vmd1.gossip.protocol.detectDeviceType
import dev.vmd1.gossip.service.SyncForegroundService

/**
 * Shows this device's own pairing QR (this device plays the Noise_IK *responder* role —
 * the same role only Mac could play before mesh support) and prompts the user to
 * confirm trust once another device scans it and dials in. See [ShowQrViewModel].
 */
class ShowQrActivity : ComponentActivity() {

    private var boundService: SyncForegroundService? = null
    private var serviceConnection: ServiceConnection? = null

    private val viewModel: ShowQrViewModel by viewModels {
        val service = boundService ?: error("Service not bound yet")
        ShowQrViewModelFactory(
            service.transportManager(),
            IdentityKeyStore.getInstance(applicationContext),
            android.os.Build.MODEL ?: "Android device",
            detectDeviceType(applicationContext)
        )
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        IdentityKeyStore.ensureInitialized(applicationContext)
        bindTransportService()
    }

    private fun bindTransportService() {
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                val local = binder as? SyncForegroundService.LocalBinder ?: return
                boundService = local.service()
                setContent {
                    dev.vmd1.gossip.ui.theme.ConnectTheme {
                        Surface(modifier = Modifier.fillMaxSize()) {
                            ShowQrScreen(
                                viewModel = viewModel,
                                onDone = { setResult(RESULT_OK); finish() },
                                onCancel = { viewModel.reset(); setResult(RESULT_CANCELED); finish() }
                            )
                        }
                    }
                }
                viewModel.startShowingQr()
            }

            override fun onServiceDisconnected(name: ComponentName?) {
                boundService = null
            }
        }
        serviceConnection = connection
        bindService(Intent(this, SyncForegroundService::class.java), connection, Context.BIND_AUTO_CREATE)
    }

    override fun onDestroy() {
        serviceConnection?.let { runCatching { unbindService(it) } }
        super.onDestroy()
    }
}

@Composable
private fun ShowQrScreen(viewModel: ShowQrViewModel, onDone: () -> Unit, onCancel: () -> Unit) {
    val state by viewModel.uiState.collectAsState()

    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        when (val current = state) {
            is ShowQrUiState.Idle -> Text("Preparing pairing code…")
            is ShowQrUiState.ShowingQr -> {
                val bitmap = remember(current.payload) { QRCodeGenerator.bitmap(current.payload) }
                Text("Scan this on another device to pair", style = MaterialTheme.typography.titleMedium)
                Image(bitmap = bitmap.asImageBitmap(), contentDescription = "Pairing QR code")
                androidx.compose.material3.OutlinedButton(onClick = onCancel) { Text("Cancel") }
            }
            is ShowQrUiState.ConfirmingTrust -> {
                Text("Waiting for confirmation…")
                var entered by remember { mutableStateOf("") }
                AlertDialog(
                    onDismissRequest = { viewModel.rejectTrust() },
                    title = { Text("Trust this device?") },
                    text = {
                        Column {
                            Text("${current.deviceName} wants to pair with this device.\n\nType the 6-digit code shown on that device. Only continue if you are looking at it right now.")
                            OutlinedTextField(value = entered, onValueChange = { entered = it.take(7) }, singleLine = true, label = { Text("123 456") })
                        }
                    },
                    confirmButton = {
                        Button(
                            onClick = { viewModel.confirmTrust() },
                            enabled = dev.vmd1.gossip.protocol.PairingCode.entryMatches(entered, current.code)
                        ) { Text("Confirm") }
                    },
                    dismissButton = {
                        Button(onClick = { viewModel.rejectTrust() }) { Text("Reject") }
                    }
                )
            }
            is ShowQrUiState.Success -> {
                Text("Paired with ${current.deviceName}", style = MaterialTheme.typography.titleMedium)
                // Both sides are paired: carry straight on to the next step.
                androidx.compose.runtime.LaunchedEffect(Unit) { onDone() }
            }
            is ShowQrUiState.Failed -> {
                Text("Pairing failed: ${current.reason}", style = MaterialTheme.typography.titleMedium)
                Button(onClick = { viewModel.startShowingQr() }) { Text("Try again") }
            }
        }
    }
}
