package dev.vmd1.gossip.pairing

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.IBinder
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.lifecycleScope
import dev.vmd1.gossip.service.SyncForegroundService
import dev.vmd1.gossip.transport.TransportManager
import dev.vmd1.gossip.transport.TransportManager.CodePairingEvent
import kotlinx.coroutines.launch

/**
 * Pairing by a short code, for when a QR can't be scanned. The *new* device shows an 8-character code; the user types it
 * into a device that is **already paired**. The key exchange itself is in the Rust core (`desktop/core`,
 * `crypto/code_pake.rs`); this screen only shows the code or takes it, and reports how it went.
 */
class CodePairActivity : ComponentActivity() {
    private var transport: TransportManager? = null
    private var serviceConnection: ServiceConnection? = null
    private var screen by mutableStateOf<CodeScreen>(CodeScreen.Choose)

    sealed class CodeScreen {
        data object Choose : CodeScreen()
        data class Showing(val code: String, val attemptsLeft: Int?) : CodeScreen()
        data object Entering : CodeScreen()
        data object Searching : CodeScreen()
        data class Paired(val name: String) : CodeScreen()
        data class Failed(val reason: String) : CodeScreen()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        bindService(
            Intent(this, SyncForegroundService::class.java),
            object : ServiceConnection {
                override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                    val service = (binder as? SyncForegroundService.LocalBinder)?.service() ?: return
                    transport = service.transportManager().also { watch(it) }
                    setContent {
                        dev.vmd1.gossip.ui.theme.ConnectTheme {
                            Surface(modifier = Modifier.fillMaxSize()) { Content() }
                        }
                    }
                }

                override fun onServiceDisconnected(name: ComponentName?) {
                    transport = null
                }
            }.also { serviceConnection = it },
            Context.BIND_AUTO_CREATE
        )
    }

    private fun watch(manager: TransportManager) {
        lifecycleScope.launch {
            manager.codePairingEvents.collect { event ->
                screen = when (event) {
                    is CodePairingEvent.Succeeded -> CodeScreen.Paired(event.peer.deviceName)
                    is CodePairingEvent.WrongCode -> (screen as? CodeScreen.Showing)?.copy(attemptsLeft = event.attemptsLeft) ?: screen
                    CodePairingEvent.TooManyAttempts -> CodeScreen.Failed("Too many wrong codes. Start again to get a new code.")
                    CodePairingEvent.Expired -> CodeScreen.Failed("The code expired. Start again to get a new one.")
                    CodePairingEvent.Rejected -> CodeScreen.Failed("That code didn't work. Check it against the other device and try again.")
                    CodePairingEvent.NoDeviceFound -> CodeScreen.Failed("No device on this network is showing a code. Open the code screen on the new device first.")
                }
                if (screen is CodeScreen.Paired) setResult(RESULT_OK)
            }
        }
    }

    @Composable
    private fun Content() {
        val manager = transport
        Column(
            modifier = Modifier.fillMaxSize().padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            when (val s = screen) {
                CodeScreen.Choose -> {
                    Text("Pair with a code", style = MaterialTheme.typography.titleLarge)
                    Text(
                        "The new device shows a code. You type it into a device that is already paired.",
                        textAlign = TextAlign.Center
                    )
                    Button(onClick = { manager?.let { screen = CodeScreen.Showing(it.startCodePairing(), null) } }) {
                        Text("This device is new: show a code")
                    }
                    Button(onClick = { screen = CodeScreen.Entering }) { Text("Add a new device: type its code") }
                    OutlinedButton(onClick = { finish() }) { Text("Cancel") }
                }
                is CodeScreen.Showing -> {
                    Text("Type this code on your other device", style = MaterialTheme.typography.titleMedium)
                    Text(s.code, fontSize = 44.sp, fontFamily = FontFamily.Monospace)
                    Text(
                        "On the device that is already paired, choose to add a device by code. Only do this with a device you own.",
                        textAlign = TextAlign.Center
                    )
                    s.attemptsLeft?.let { Text("A wrong code was entered ($it tries left).", color = MaterialTheme.colorScheme.error) }
                    CircularProgressIndicator()
                    OutlinedButton(onClick = { manager?.stopCodePairing(); finish() }) { Text("Cancel") }
                }
                CodeScreen.Entering -> {
                    var typed by remember { mutableStateOf("") }
                    Text("Type the code shown on the new device", style = MaterialTheme.typography.titleMedium)
                    OutlinedTextField(
                        value = typed,
                        onValueChange = { typed = it.take(12).uppercase() },
                        singleLine = true,
                        label = { Text("ABCD-EFGH") }
                    )
                    Button(
                        onClick = { screen = CodeScreen.Searching; manager?.enterCode(typed) },
                        enabled = typed.count { it.isLetterOrDigit() } >= 8
                    ) { Text("Pair") }
                    OutlinedButton(onClick = { finish() }) { Text("Cancel") }
                }
                CodeScreen.Searching -> {
                    Text("Looking for the new device…", style = MaterialTheme.typography.titleMedium)
                    CircularProgressIndicator()
                    OutlinedButton(onClick = { finish() }) { Text("Cancel") }
                }
                is CodeScreen.Paired -> {
                    Text("Paired with ${s.name}", style = MaterialTheme.typography.titleMedium)
                    Button(onClick = { finish() }) { Text("Done") }
                }
                is CodeScreen.Failed -> {
                    Text("Pairing didn't work", style = MaterialTheme.typography.titleMedium)
                    Text(s.reason, textAlign = TextAlign.Center)
                    Button(onClick = { screen = CodeScreen.Choose }) { Text("Try again") }
                    OutlinedButton(onClick = { finish() }) { Text("Close") }
                }
            }
        }
    }

    override fun onDestroy() {
        if (screen is CodeScreen.Showing) transport?.stopCodePairing()
        serviceConnection?.let { runCatching { unbindService(it) } }
        super.onDestroy()
    }
}
