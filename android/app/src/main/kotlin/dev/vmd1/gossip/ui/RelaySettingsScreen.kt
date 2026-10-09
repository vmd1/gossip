package dev.vmd1.gossip.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import dev.vmd1.gossip.transport.RelayEndpointPolicy
import dev.vmd1.gossip.transport.RelaySettings
import kotlinx.coroutines.flow.StateFlow

/** The relay client's live state, as the transport publishes it. */
class RelayUiState(val status: StateFlow<String>, val idle: StateFlow<Boolean>, val errorCode: StateFlow<String?>)

/** What the Settings status line says about the relay, from the engine's `relay_status` string. */
object RelayStatusText {
    fun line(enabled: Boolean, hasOrigin: Boolean, status: String, idle: Boolean, errorCode: String?): String {
        if (!enabled) return "Off"
        if (!hasOrigin) return "No relay host configured"
        if (idle) return "On, waiting: all your devices are on this network"
        return when (status) {
            "joined" -> "Connected to the relay"
            "connecting" -> "Connecting…"
            "disconnected" -> errorCode?.let { hint(it) } ?: "Not connected, retrying"
            "no_topic" -> "Waiting for a paired device on the same network (the first connection sets the relay up)"
            else -> "Off"
        }
    }

    private fun hint(code: String): String? = when (code) {
        "upgrade_required" -> "The relay needs a newer version of Gossip"
        "denied", "join_failed" -> "The relay refused this device, retrying"
        "disabled" -> "The relay is switched off by its operator"
        else -> null
    }
}

fun relayFailureMessage(failure: RelayEndpointPolicy.Failure): String = when (failure) {
    RelayEndpointPolicy.Failure.MALFORMED -> "That is not a valid address. Use the form wss://relay.example.com"
    RelayEndpointPolicy.Failure.INSECURE_SCHEME -> "The address must start with wss:// (an encrypted connection)."
    RelayEndpointPolicy.Failure.CREDENTIALS_NOT_ALLOWED -> "Do not put a user name or password in the address."
    RelayEndpointPolicy.Failure.UNEXPECTED_COMPONENTS -> "Use just the host, like wss://relay.example.com (no path or query)."
    RelayEndpointPolicy.Failure.HOST_NOT_ALLOWED -> "That host is not allowed."
}

/** Settings > Relay: the opt-in for connecting to paired devices when they are not on the same network. Off by default. */
@Composable
fun ColumnScope.RelaySettingsContent(settings: RelaySettings, state: RelayUiState?) {
    val enabled by settings.enabled.collectAsState()
    val customUrl by settings.customUrl.collectAsState()
    var text by remember { mutableStateOf(customUrl) }
    var error by remember { mutableStateOf<String?>(null) }

    fun commit() {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) {
            settings.setCustomUrl("")
            error = null
            return
        }
        when (val result = RelayEndpointPolicy.normalizeOrigin(trimmed)) {
            is RelayEndpointPolicy.Result.Ok -> {
                text = result.origin
                settings.setCustomUrl(result.origin)
                error = null
            }
            is RelayEndpointPolicy.Result.Error -> error = relayFailureMessage(result.failure)
        }
    }
    // A typed address that was never confirmed would otherwise be lost silently when leaving the page.
    DisposableEffect(Unit) { onDispose { if (text.trim() != customUrl && error == null) commit() } }

    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(modifier = Modifier.weight(1f).padding(end = 12.dp)) {
            Text("Relay (connect when not on the same network)", style = MaterialTheme.typography.bodyLarge)
            Text(
                "Keeps your paired devices connected over the internet when they are not on the same network. " +
                    "Same-network connections are always preferred.",
                style = MaterialTheme.typography.bodySmall
            )
        }
        Switch(checked = enabled, onCheckedChange = { settings.setEnabled(it) })
    }

    OutlinedTextField(
        value = text,
        onValueChange = { text = it; error = null },
        modifier = Modifier.fillMaxWidth(),
        label = { Text("Custom relay address (optional)") },
        placeholder = { Text("wss://relay.example.com") },
        singleLine = true,
        isError = error != null,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Done),
        keyboardActions = KeyboardActions(onDone = { commit() })
    )
    error?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error) }
    if (text.trim() != customUrl) TextButton(onClick = { commit() }) { Text("Save address") }

    val hasOrigin = RelayEndpointPolicy.resolveOrigin(customUrl) is RelayEndpointPolicy.Result.Ok
    val status by (state?.status?.collectAsState() ?: remember { mutableStateOf("disabled") })
    val idle by (state?.idle?.collectAsState() ?: remember { mutableStateOf(false) })
    val errorCode by (state?.errorCode?.collectAsState() ?: remember { mutableStateOf<String?>(null) })
    Column {
        Text("Status", style = MaterialTheme.typography.labelMedium)
        Text(RelayStatusText.line(enabled, hasOrigin, status, idle, errorCode), style = MaterialTheme.typography.bodyMedium)
    }

    Text(
        "The relay sees which network addresses connect and when, and how much data flows, but not what you send: " +
            "everything is end-to-end encrypted between your devices. Screen mirroring and Universal Control only work " +
            "on the same network.",
        style = MaterialTheme.typography.bodySmall
    )
}
