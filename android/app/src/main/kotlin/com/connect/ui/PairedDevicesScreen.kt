package com.connect.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.connect.crypto.TrustedDevice

/** Lists trusted devices from the `TrustedDevices` table, each with a "Forget" action
 *  that revokes trust (see [com.connect.crypto.TrustedDevicesStore.revoke]). */
@Composable
fun PairedDevicesScreen(devices: List<TrustedDevice>, onForget: (deviceId: String) -> Unit) {
    Column {
        Text("Paired devices", style = MaterialTheme.typography.titleMedium)
        if (devices.isEmpty()) {
            Text("No devices paired yet.")
            return
        }
        LazyColumn {
            items(devices, key = { it.deviceId }) { device ->
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
            }
        }
    }
}
