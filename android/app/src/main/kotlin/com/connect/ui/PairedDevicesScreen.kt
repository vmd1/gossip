package com.connect.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import com.connect.crypto.TrustedDevice

/** Lists trusted devices from the `TrustedDevices` table, each with a "Forget" action
 *  that revokes trust (see [com.connect.crypto.TrustedDevicesStore.revoke]) and a
 *  fallback-address field (see [TrustedDevice.fallbackHost] /
 *  `SyncForegroundService.runFallbackDialLoop`) for reaching this peer when it isn't
 *  visible over local mDNS discovery — e.g. a Tailscale IP for a Mac on another network. */
@Composable
fun PairedDevicesScreen(
    devices: List<TrustedDevice>,
    onForget: (deviceId: String) -> Unit,
    onSetFallbackHost: (deviceId: String, fallbackHost: String?) -> Unit = { _, _ -> }
) {
    Column {
        Text("Paired devices", style = MaterialTheme.typography.titleMedium)
        if (devices.isEmpty()) {
            Text("No devices paired yet.")
            return
        }
        LazyColumn {
            items(devices, key = { it.deviceId }) { device ->
                Column(modifier = Modifier.fillMaxWidth()) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Column {
                            Text(device.deviceName)
                            Text(device.deviceType.wireValue, style = MaterialTheme.typography.bodySmall)
                        }
                        TextButton(onClick = { onForget(device.deviceId) }) {
                            Text("Forget")
                        }
                    }
                    FallbackHostField(device = device, onSetFallbackHost = onSetFallbackHost)
                }
            }
        }
    }
}

/** Editable field for [TrustedDevice.fallbackHost], committed on "Done"/IME action or
 *  focus loss rather than on every keystroke, so a fallback dial attempt never fires
 *  against a half-typed address. */
@Composable
private fun FallbackHostField(
    device: TrustedDevice,
    onSetFallbackHost: (deviceId: String, fallbackHost: String?) -> Unit
) {
    var text by remember(device.deviceId) { mutableStateOf(device.fallbackHost.orEmpty()) }
    OutlinedTextField(
        value = text,
        onValueChange = { text = it },
        label = { Text("Fallback IP (e.g. Tailscale)") },
        placeholder = { Text("100.x.x.x") },
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Done),
        keyboardActions = KeyboardActions(onDone = { onSetFallbackHost(device.deviceId, text) }),
        modifier = Modifier.fillMaxWidth()
    )
}
