package com.connect.pairing

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
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.unit.dp
import com.connect.crypto.IdentityKeyStore
import com.connect.protocol.detectDeviceType
import com.connect.service.SyncForegroundService

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
                    MaterialTheme {
                        Surface(modifier = Modifier.fillMaxSize()) {
                            ShowQrScreen(viewModel = viewModel, onDone = { finish() })
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
private fun ShowQrScreen(viewModel: ShowQrViewModel, onDone: () -> Unit) {
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
            }
            is ShowQrUiState.ConfirmingTrust -> {
                Text("Waiting for confirmation…")
                AlertDialog(
                    onDismissRequest = { viewModel.rejectTrust() },
                    title = { Text("Trust this device?") },
                    text = { Text("${current.deviceName} wants to pair with this device.") },
                    confirmButton = {
                        Button(onClick = { viewModel.confirmTrust() }) { Text("Confirm") }
                    },
                    dismissButton = {
                        Button(onClick = { viewModel.rejectTrust() }) { Text("Reject") }
                    }
                )
            }
            is ShowQrUiState.Success -> {
                Text("Paired with ${current.deviceName}", style = MaterialTheme.typography.titleMedium)
                Button(onClick = onDone) { Text("Done") }
            }
            is ShowQrUiState.Failed -> {
                Text("Pairing failed: ${current.reason}", style = MaterialTheme.typography.titleMedium)
                Button(onClick = { viewModel.startShowingQr() }) { Text("Try again") }
            }
        }
    }
}
