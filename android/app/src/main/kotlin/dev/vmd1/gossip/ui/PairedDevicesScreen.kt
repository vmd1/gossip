package dev.vmd1.gossip.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
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
import dev.vmd1.gossip.features.battery.BatteryState
import dev.vmd1.gossip.features.battery.BatterySyncManager
import dev.vmd1.gossip.features.hotspot.HotspotState
import androidx.compose.material.icons.filled.NotificationsActive
import androidx.compose.material.icons.filled.Battery2Bar
import androidx.compose.material.icons.filled.Battery3Bar
import androidx.compose.material.icons.filled.Battery4Bar
import androidx.compose.material.icons.filled.Battery5Bar
import androidx.compose.material.icons.filled.Battery6Bar
import androidx.compose.material.icons.filled.BatteryAlert
import androidx.compose.material.icons.filled.BatteryChargingFull
import androidx.compose.material.icons.filled.BatteryFull
import androidx.compose.foundation.layout.size
import dev.vmd1.gossip.protocol.DeviceType
import dev.vmd1.gossip.transport.Connectivity
import dev.vmd1.gossip.transport.DeviceConnectivity

/** Icon shown in place of the old plain-text device-type subtitle. */
private val DeviceType.icon: ImageVector
    get() = when (this) {
        DeviceType.MAC -> Icons.Default.Laptop
        DeviceType.ANDROID_PHONE -> Icons.Default.PhoneAndroid
        DeviceType.ANDROID_TABLET -> Icons.Default.TabletMac
    }

private const val HOTSPOT_OVERRIDE_MS = 30_000L

/** One line under the device name: battery icon + level, then "Nearby" when in Bluetooth range
 *  (same layout as the Mac's device rows). Draws nothing when there is neither. */
@Composable
private fun DeviceSubtitle(battery: BatteryState?, nearby: Boolean, modifier: Modifier = Modifier) {
    if (battery == null && !nearby) return
    val muted = MaterialTheme.colorScheme.onSurfaceVariant
    Row(modifier = modifier, verticalAlignment = Alignment.CenterVertically) {
        if (battery != null) {
            val low = battery.level <= BatterySyncManager.LOW_THRESHOLD && !battery.isCharging
            val tint = if (low) MaterialTheme.colorScheme.error else muted
            Icon(
                imageVector = batteryIcon(battery),
                contentDescription = "Battery ${battery.level}%" + if (battery.isCharging) ", charging" else "",
                tint = tint,
                modifier = Modifier.size(16.dp)
            )
            Text(" ${battery.level}%", style = MaterialTheme.typography.bodySmall, color = tint)
        }
        if (battery != null && nearby) Text("  ·  ", style = MaterialTheme.typography.bodySmall, color = muted)
        if (nearby) Text("Nearby", style = MaterialTheme.typography.bodySmall, color = muted)
    }
}

/** Battery glyph for a reported level: charging bolt, low-battery alert, else a level-matched bar icon. */
private fun batteryIcon(b: BatteryState): ImageVector = when {
    b.isCharging -> Icons.Default.BatteryChargingFull
    b.level <= BatterySyncManager.LOW_THRESHOLD -> Icons.Default.BatteryAlert
    b.level >= 95 -> Icons.Default.BatteryFull
    b.level >= 80 -> Icons.Default.Battery6Bar
    b.level >= 65 -> Icons.Default.Battery5Bar
    b.level >= 50 -> Icons.Default.Battery4Bar
    b.level >= 35 -> Icons.Default.Battery3Bar
    else -> Icons.Default.Battery2Bar
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
    hotspotStates: Map<String, HotspotState> = emptyMap(),
    bleHotspotOnStates: Map<String, Boolean> = emptyMap(),
    onRequestHotspot: (deviceId: String, enable: Boolean) -> Unit = { _, _ -> },
    hotspotOverrides: Map<String, Pair<Boolean, Long>> = emptyMap(),
    directDeviceIds: Set<String> = emptySet(),
    meshDeviceIds: Set<String> = emptySet(),
    relayedDeviceIds: Set<String> = emptySet(),
    batteryStates: Map<String, BatteryState> = emptyMap(),
    ringingPeers: Set<String> = emptySet(),
    onToggleRing: (deviceId: String) -> Unit = {}
) {
    Column {
        Text("Paired devices", style = MaterialTheme.typography.titleMedium)
        if (devices.isEmpty()) {
            Text("No devices paired yet. Open Settings to pair one.")
            return
        }
        LazyColumn {
            items(devices, key = { it.deviceId }) { device ->
                Column {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Row(modifier = Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically) {
                        // Green = connected directly, teal = connected through the relay, blue = reachable over the mesh,
                        // grey = not connected.
                        val connectivity = DeviceConnectivity.classify(device.deviceId, directDeviceIds, meshDeviceIds, relayedDeviceIds)
                        Icon(
                            imageVector = device.deviceType.icon,
                            contentDescription = device.deviceType.wireValue + when (connectivity) {
                                Connectivity.DIRECT -> ", connected"
                                Connectivity.RELAYED -> ", connected through the relay (screen mirroring and Universal Control need the same network)"
                                Connectivity.MESH -> ", connected through another device"
                                Connectivity.NONE -> ", not connected"
                            },
                            tint = when (connectivity) {
                                Connectivity.DIRECT -> androidx.compose.ui.graphics.Color(0xFF34C759)
                                Connectivity.RELAYED -> androidx.compose.ui.graphics.Color(0xFF30B0C7)
                                Connectivity.MESH -> androidx.compose.ui.graphics.Color(0xFF0A84FF)
                                Connectivity.NONE -> MaterialTheme.colorScheme.onSurfaceVariant
                            },
                            modifier = Modifier.padding(end = 8.dp)
                        )
                        Column {
                            Text(device.deviceName, maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
                            if (connectivity == Connectivity.RELAYED) {
                                Text(
                                    "Through the relay. Screen mirroring and Universal Control need the same network.",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }
                    }
                    // Grouped in their own Row (not two more top-level children of the
                    // outer SpaceBetween Row) — real layout bug, confirmed live: with
                    // three top-level children, SpaceBetween spaced the hotspot icon
                    // in the middle of the row instead of keeping it against the right
                    // edge next to the settings button.
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        // Press to ring; blue while it's ringing; press again to stop.
                        val ringing = device.deviceId in ringingPeers
                        IconButton(onClick = { onToggleRing(device.deviceId) }) {
                            Icon(
                                Icons.Default.NotificationsActive,
                                contentDescription = if (ringing) "Stop ringing ${device.deviceName}" else "Ring ${device.deviceName}",
                                tint = if (ringing) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
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
                            val underlying = when {
                                bleOn != null && meshState != null -> meshState.copy(enabled = bleOn)
                                bleOn != null -> HotspotState(enabled = bleOn)
                                else -> meshState
                            }
                            // Both sources lag a real toggle by several seconds; trust what the phone
                            // itself just confirmed over GATT until they agree (or 30s pass).
                            val override = hotspotOverrides[device.deviceId]
                            val state = if (override != null && System.currentTimeMillis() - override.second < HOTSPOT_OVERRIDE_MS &&
                                underlying?.enabled != override.first
                            ) HotspotState(override.first, if (override.first) underlying?.ssid else null) else underlying
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
                            onSetLockOnLeave = onSetLockOnLeave
                        )
                    }
                }
                DeviceSubtitle(
                    battery = batteryStates[device.deviceId],
                    nearby = device.deviceId in nearbyDeviceIds,
                    modifier = Modifier.padding(start = 32.dp).offset(y = (-10).dp)
                )
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
    onSetLockOnLeave: (deviceId: String, enabled: Boolean) -> Unit = { _, _ -> }
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
    onForget: () -> Unit,
    onDismiss: () -> Unit
) {
    var showForgetConfirmation by remember { mutableStateOf(false) }
    // Hoisted so Done / tapping outside the dialog also saves it, not just the keyboard's Done key.
    var fallbackText by remember(device.deviceId) { mutableStateOf(device.fallbackHost.orEmpty()) }
    fun saveFallback() {
        if (fallbackText.trim() != device.fallbackHost.orEmpty()) onSetFallbackHost(device.deviceId, fallbackText)
    }
    fun commitAndDismiss() { saveFallback(); onDismiss() }

    Dialog(onDismissRequest = ::commitAndDismiss) {
        Surface(shape = RoundedCornerShape(16.dp)) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                Text("${device.deviceName} Settings", style = MaterialTheme.typography.titleMedium)

                FallbackHostField(text = fallbackText, onTextChange = { fallbackText = it }, onCommit = ::saveFallback)

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

                OutlinedButton(onClick = { showForgetConfirmation = true }) {
                    Text("Forget This Device…")
                }

                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    TextButton(onClick = ::commitAndDismiss) {
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

/** Editable field for [TrustedDevice.fallbackHost]. The owner holds the text and saves it; this calls
 *  [onCommit] on the keyboard's Done key and ~0.8s after the user stops typing (so a fallback dial
 *  never fires against a half-typed address on every keystroke, but a value is never lost just
 *  because the dialog was closed without pressing the keyboard's Done key). */
@Composable
private fun FallbackHostField(
    text: String,
    onTextChange: (String) -> Unit,
    onCommit: () -> Unit,
    modifier: Modifier = Modifier.fillMaxWidth()
) {
    androidx.compose.runtime.LaunchedEffect(text) {
        kotlinx.coroutines.delay(800)
        onCommit()
    }
    OutlinedTextField(
        value = text,
        onValueChange = onTextChange,
        label = { Text("Fallback IP (e.g. Tailscale)") },
        placeholder = { Text("100.x.x.x") },
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Done),
        keyboardActions = KeyboardActions(onDone = { onCommit() }),
        modifier = modifier
    )
}
