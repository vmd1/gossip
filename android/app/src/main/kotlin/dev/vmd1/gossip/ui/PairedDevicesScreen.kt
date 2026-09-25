package dev.vmd1.gossip.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bluetooth
import androidx.compose.material.icons.filled.Laptop
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.TabletMac
import androidx.compose.material.icons.filled.WifiTethering
import androidx.compose.material.icons.filled.WifiTetheringOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.window.Dialog
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import dev.vmd1.gossip.crypto.TrustedDevice
import dev.vmd1.gossip.features.hotspot.HotspotState
import dev.vmd1.gossip.protocol.DeviceType

/** Icon shown in place of the old plain-text device-type subtitle. */
private val DeviceType.icon: ImageVector
    get() = when (this) {
        DeviceType.MAC -> Icons.Default.Laptop
        DeviceType.ANDROID_PHONE -> Icons.Default.PhoneAndroid
        DeviceType.ANDROID_TABLET -> Icons.Default.TabletMac
    }

/** Lists trusted devices from the `TrustedDevices` table, each with a "Forget" action
 *  that revokes trust (see [dev.vmd1.gossip.crypto.TrustedDevicesStore.revoke]) and a
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
    onSetLockOnLeave: (deviceId: String, enabled: Boolean) -> Unit = { _, _ -> },
    onSetAutoHotspotRequestEligible: (deviceId: String, eligible: Boolean) -> Unit = { _, _ -> },
    hotspotStates: Map<String, HotspotState> = emptyMap(),
    bleHotspotOnStates: Map<String, Boolean> = emptyMap(),
    onRequestHotspot: (deviceId: String, enable: Boolean) -> Unit = { _, _ -> }
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
                    // Grouped in their own Row (not two more top-level children of the
                    // outer SpaceBetween Row) — real layout bug, confirmed live: with
                    // three top-level children, SpaceBetween spaced the hotspot icon
                    // in the middle of the row instead of keeping it against the right
                    // edge next to the settings button.
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        if (device.deviceType == DeviceType.ANDROID_PHONE) {
                            // Prefer the BLE-observed on/off bit when nearby — it stays
                            // live even with no mesh connection to this device at all,
                            // unlike hotspotStates (mesh-only, can go stale the moment
                            // the mesh connection drops). Falls back to the
                            // mesh-reported state (which also carries the SSID for the
                            // tooltip) when not BLE-nearby, or merges the fresher
                            // `enabled` bit in when both sources exist.
                            val bleOn = if (device.deviceId in nearbyDeviceIds) bleHotspotOnStates[device.deviceId] else null
                            val meshState = hotspotStates[device.deviceId]
                            val state = when {
                                bleOn != null && meshState != null -> meshState.copy(enabled = bleOn)
                                bleOn != null -> HotspotState(enabled = bleOn)
                                else -> meshState
                            }
                            state?.let { s ->
                                IconButton(onClick = { onRequestHotspot(device.deviceId, !s.enabled) }) {
                                    Icon(
                                        imageVector = if (s.enabled) Icons.Default.WifiTethering else Icons.Default.WifiTetheringOff,
                                        contentDescription = if (s.enabled) {
                                            "Instant Hotspot is on" + (s.ssid?.let { ssid -> " ($ssid)" } ?: "") + " — tap to turn off"
                                        } else {
                                            "Instant Hotspot is off — tap to request"
                                        },
                                        tint = if (s.enabled) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }
                            }
                        }
                        DeviceSettingsButton(
                            device = device,
                            onForget = onForget,
                            onSetFallbackHost = onSetFallbackHost,
                            showLockOnLeaveToggle = myDeviceType == DeviceType.ANDROID_PHONE && device.deviceType != DeviceType.ANDROID_PHONE,
                            onSetLockOnLeave = onSetLockOnLeave,
                            showAutoHotspotRequestToggle = device.deviceType == DeviceType.ANDROID_PHONE,
                            onSetAutoHotspotRequestEligible = onSetAutoHotspotRequestEligible
                        )
                    }
                }
            }
        }
    }
}

/** Settings for one specific trusted device that don't need to be on the home row:
 *  fallback-host override and revoking trust today; per-pair BLE-driven settings
 *  (Lock-on-Leave, auto-hotspot) land here too once built.
 *
 *  Opens a real [Dialog] rather than a [androidx.compose.material3.DropdownMenu] — a
 *  cramped inline dropdown was the wrong container for a text field plus a switch plus
 *  a destructive action; a modal gives each control room and a clear Done/Cancel
 *  affordance, matching the equivalent `DeviceSettingsWindow` on the Mac side. */
@Composable
private fun DeviceSettingsButton(
    device: TrustedDevice,
    onForget: (deviceId: String) -> Unit,
    onSetFallbackHost: (deviceId: String, fallbackHost: String?) -> Unit,
    showLockOnLeaveToggle: Boolean = false,
    onSetLockOnLeave: (deviceId: String, enabled: Boolean) -> Unit = { _, _ -> },
    showAutoHotspotRequestToggle: Boolean = false,
    onSetAutoHotspotRequestEligible: (deviceId: String, eligible: Boolean) -> Unit = { _, _ -> }
) {
    var showSettings by remember { mutableStateOf(false) }
    IconButton(onClick = { showSettings = true }) {
        Icon(Icons.Default.MoreVert, contentDescription = "Device settings")
    }
    if (showSettings) {
        DeviceSettingsDialog(
            device = device,
            onSetFallbackHost = onSetFallbackHost,
            showLockOnLeaveToggle = showLockOnLeaveToggle,
            onSetLockOnLeave = onSetLockOnLeave,
            showAutoHotspotRequestToggle = showAutoHotspotRequestToggle,
            onSetAutoHotspotRequestEligible = onSetAutoHotspotRequestEligible,
            onForget = {
                onForget(device.deviceId)
                showSettings = false
            },
            onDismiss = { showSettings = false }
        )
    }
}

@Composable
private fun DeviceSettingsDialog(
    device: TrustedDevice,
    onSetFallbackHost: (deviceId: String, fallbackHost: String?) -> Unit,
    showLockOnLeaveToggle: Boolean,
    onSetLockOnLeave: (deviceId: String, enabled: Boolean) -> Unit,
    showAutoHotspotRequestToggle: Boolean = false,
    onSetAutoHotspotRequestEligible: (deviceId: String, eligible: Boolean) -> Unit = { _, _ -> },
    onForget: () -> Unit,
    onDismiss: () -> Unit
) {
    var showForgetConfirmation by remember { mutableStateOf(false) }

    Dialog(onDismissRequest = onDismiss) {
        Surface(shape = RoundedCornerShape(16.dp)) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                Text("${device.deviceName} Settings", style = MaterialTheme.typography.titleMedium)

                FallbackHostField(device = device, onSetFallbackHost = onSetFallbackHost)

                // Per-pair, BLE-driven: lock this specific Mac/tablet when this (phone) device
                // leaves its BLE range (see docs/ble-proximity-protocol.md / schema/message-
                // types.md's lock_on_leave.config). Only meaningful when I'm a phone (only
                // phones are BLE-detectable — see BLEProximityMonitor's role split) and the
                // target isn't a phone (nothing locks a phone this way).
                if (showLockOnLeaveToggle) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text("Lock this device when I leave")
                        Switch(
                            checked = device.lockOnLeaveEnabled,
                            onCheckedChange = { onSetLockOnLeave(device.deviceId, it) }
                        )
                    }
                }

                // Per-phone eligibility for *my* WAN-offline auto-request-hotspot trigger
                // (docs/ble-hotspot-protocol.md) — the other half of this is the global
                // per-device switch on the home screen (OnboardingPreferences.
                // autoRequestHotspotEnabled). Shown on any phone row regardless of my own
                // device type, since a Mac, tablet, or another phone can all auto-request.
                if (showAutoHotspotRequestToggle) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text("Eligible for auto-request hotspot")
                        Switch(
                            checked = device.autoHotspotRequestEligible,
                            onCheckedChange = { onSetAutoHotspotRequestEligible(device.deviceId, it) }
                        )
                    }
                }

                OutlinedButton(onClick = { showForgetConfirmation = true }) {
                    Text("Forget This Device…")
                }

                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    TextButton(onClick = onDismiss) {
                        Text("Done")
                    }
                }
            }
        }
    }

    if (showForgetConfirmation) {
        AlertDialog(
            onDismissRequest = { showForgetConfirmation = false },
            title = { Text("Forget ${device.deviceName}?") },
            text = { Text("This device will no longer trust ${device.deviceName}. You'll need to pair again to reconnect.") },
            confirmButton = {
                TextButton(onClick = onForget) { Text("Forget") }
            },
            dismissButton = {
                TextButton(onClick = { showForgetConfirmation = false }) { Text("Cancel") }
            }
        )
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
