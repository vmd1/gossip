package com.connect.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bluetooth
import androidx.compose.material.icons.filled.Laptop
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.TabletMac
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import com.connect.crypto.TrustedDevice
import com.connect.protocol.DeviceType

/** Icon shown in place of the old plain-text device-type subtitle. */
private val DeviceType.icon: ImageVector
    get() = when (this) {
        DeviceType.MAC -> Icons.Default.Laptop
        DeviceType.ANDROID_PHONE -> Icons.Default.PhoneAndroid
        DeviceType.ANDROID_TABLET -> Icons.Default.TabletMac
    }

/** Lists trusted devices from the `TrustedDevices` table, each with a "Forget" action
 *  that revokes trust (see [com.connect.crypto.TrustedDevicesStore.revoke]) and a
 *  fallback-address field (see [TrustedDevice.fallbackHost] /
 *  `SyncForegroundService.runFallbackDialLoop`) for reaching this peer when it isn't
 *  visible over local mDNS discovery — e.g. a Tailscale IP for a Mac on another network. */
@Composable
fun PairedDevicesScreen(
    devices: List<TrustedDevice>,
    onForget: (deviceId: String) -> Unit,
    onSetFallbackHost: (deviceId: String, fallbackHost: String?) -> Unit = { _, _ -> },
    nearbyDeviceIds: Set<String> = emptySet(),
    myDeviceType: DeviceType = DeviceType.ANDROID_PHONE,
    onSetLockOnLeave: (deviceId: String, enabled: Boolean) -> Unit = { _, _ -> }
) {
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
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(
                            imageVector = device.deviceType.icon,
                            contentDescription = device.deviceType.wireValue,
                            modifier = Modifier.padding(end = 8.dp)
                        )
                        Text(device.deviceName)
                        if (device.deviceId in nearbyDeviceIds) {
                            Icon(
                                imageVector = Icons.Default.Bluetooth,
                                contentDescription = "Nearby over Bluetooth",
                                modifier = Modifier.padding(start = 8.dp)
                            )
                        }
                    }
                    DeviceSettingsMenu(
                        device = device,
                        onForget = onForget,
                        onSetFallbackHost = onSetFallbackHost,
                        showLockOnLeaveToggle = myDeviceType == DeviceType.ANDROID_PHONE && device.deviceType != DeviceType.ANDROID_PHONE,
                        onSetLockOnLeave = onSetLockOnLeave
                    )
                }
            }
        }
    }
}

/** Overflow menu for settings that apply to one specific trusted device but don't need
 *  to be on the home row: revoking trust and the fallback-host override today; per-pair
 *  BLE-driven settings (Lock-on-Leave, auto-hotspot) land here too once built. */
@Composable
private fun DeviceSettingsMenu(
    device: TrustedDevice,
    onForget: (deviceId: String) -> Unit,
    onSetFallbackHost: (deviceId: String, fallbackHost: String?) -> Unit,
    showLockOnLeaveToggle: Boolean = false,
    onSetLockOnLeave: (deviceId: String, enabled: Boolean) -> Unit = { _, _ -> }
) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { expanded = true }) {
            Icon(Icons.Default.MoreVert, contentDescription = "Device settings")
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            FallbackHostField(
                device = device,
                onSetFallbackHost = onSetFallbackHost,
                modifier = Modifier
                    .width(240.dp)
                    .padding(horizontal = 12.dp, vertical = 4.dp)
            )
            // Per-pair, BLE-driven: lock this specific Mac/tablet when this (phone) device
            // leaves its BLE range (see docs/ble-proximity-protocol.md / schema/message-
            // types.md's lock_on_leave.config). Only meaningful when I'm a phone (only
            // phones are BLE-detectable — see BLEProximityMonitor's role split) and the
            // target isn't a phone (nothing locks a phone this way).
            if (showLockOnLeaveToggle) {
                DropdownMenuItem(
                    text = { Text("Lock this device when I leave") },
                    trailingIcon = {
                        androidx.compose.material3.Switch(
                            checked = device.lockOnLeaveEnabled,
                            onCheckedChange = { onSetLockOnLeave(device.deviceId, it) }
                        )
                    },
                    onClick = { onSetLockOnLeave(device.deviceId, !device.lockOnLeaveEnabled) }
                )
            }
            DropdownMenuItem(
                text = { Text("Forget") },
                onClick = {
                    expanded = false
                    onForget(device.deviceId)
                }
            )
        }
    }
}

/** Editable field for [TrustedDevice.fallbackHost], committed on "Done"/IME action or
 *  focus loss rather than on every keystroke, so a fallback dial attempt never fires
 *  against a half-typed address. */
@Composable
private fun FallbackHostField(
    device: TrustedDevice,
    onSetFallbackHost: (deviceId: String, fallbackHost: String?) -> Unit,
    modifier: Modifier = Modifier.fillMaxWidth()
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
        modifier = modifier
    )
}
