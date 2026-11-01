package dev.vmd1.gossip.ui

import android.content.Intent
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.graphics.drawable.toBitmap
import dev.vmd1.gossip.features.clipboard.ClipboardHistoryStore
import dev.vmd1.gossip.features.notifications.NotificationForwardSettings
import dev.vmd1.gossip.features.settings.Feature
import dev.vmd1.gossip.features.settings.FeatureSettings
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** The Settings menu and its sub-pages. [parent] is where Back goes (null = back to the home screen). */
enum class SettingsPage(val parent: SettingsPage?) {
    ROOT(null),
    DEVICES(ROOT),
    NOTIFICATIONS(ROOT),
    NOTIFICATION_APPS(NOTIFICATIONS),
    FEATURES(ROOT),
    RELAY(ROOT),
    HOTSPOT(FEATURES),
    CLIPBOARD_HISTORY(FEATURES),
    /** The same page opened from the home screen's button, so Back returns home rather than to Features. */
    CLIPBOARD_HOME(null),
    MESSAGES(FEATURES),
    PERMISSIONS(ROOT)
}

/** Shared chrome for every Settings page: a back arrow + title, then [content]. Set [scroll] to
 *  `false` when the content brings its own scrolling list (e.g. [NotificationAppsContent]). */
@Composable
fun SettingsPageScaffold(
    title: String,
    onBack: () -> Unit,
    scroll: Boolean = true,
    content: @Composable ColumnScope.() -> Unit
) {
    Scaffold { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(horizontal = 12.dp, vertical = 8.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onBack) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                }
                Text(title, style = MaterialTheme.typography.headlineSmall)
            }
            Column(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .then(if (scroll) Modifier.verticalScroll(rememberScrollState()) else Modifier)
                    .padding(horizontal = 12.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
                content = content
            )
        }
    }
}

/** A tappable card that opens a sub-page: title, one-line summary, chevron. */
@Composable
fun SettingsMenuRow(title: String, subtitle: String, onClick: () -> Unit) {
    Surface(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick),
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surfaceVariant
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.titleMedium)
                Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null)
        }
    }
}

/** Settings → Features: one on/off switch per feature for *this* device (all on by default). Turning
 *  one off makes this device stop sending and receiving it entirely — see [FeatureSettings]. */
@Composable
fun ColumnScope.FeatureTogglesContent(
    settings: FeatureSettings,
    isPhone: Boolean = true,
    onConfigure: (SettingsPage) -> Unit = {}
) {
    val context = LocalContext.current
    val disabled by settings.disabled.collectAsState()
    val messages = remember { dev.vmd1.gossip.features.messages.MessagesSettings.getInstance(context) }
    val messagesOn by messages.enabled.collectAsState()
    val history = remember { ClipboardHistoryStore.getInstance(context) }
    val historyOn by history.enabled.collectAsState()
    val screenOff = remember { dev.vmd1.gossip.features.screenmirror.ScreenOffMirrorSettings.getInstance(context) }
    val screenOffOn by screenOff.enabled.collectAsState()
    Text(
        "Turning a feature off stops this device from sending or receiving it at all. " +
            "Your other devices keep their own settings. The ⋮ button opens a feature's own settings.",
        style = MaterialTheme.typography.bodySmall
    )
    @Composable
    fun FeatureRow(title: String, detail: String, checked: Boolean, onChecked: (Boolean) -> Unit, configure: SettingsPage?) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.weight(1f).padding(end = 8.dp)) {
                Text(title, style = MaterialTheme.typography.bodyLarge)
                Text(detail, style = MaterialTheme.typography.bodySmall)
            }
            if (configure != null) {
                IconButton(onClick = { onConfigure(configure) }) {
                    Icon(androidx.compose.material.icons.Icons.Default.MoreVert, contentDescription = "$title settings")
                }
            }
            Switch(checked = checked, onCheckedChange = onChecked)
        }
    }
    for (feature in Feature.values()) {
        if (feature == Feature.HOTSPOT && !isPhone) continue
        FeatureRow(
            feature.title, feature.detail, feature !in disabled, { settings.setEnabled(feature, it) },
            if (feature == Feature.HOTSPOT) SettingsPage.HOTSPOT else null
        )
    }
    FeatureRow(
        "Screen-off mirroring",
        "Keep this screen dark while it's mirrored (needs Shizuku). It sleeps and locks again when mirroring ends.",
        screenOffOn, { screenOff.setEnabled(it) }, null
    )
    if (isPhone) {
        FeatureRow(
            "Messages", "Let your paired Mac read and send this phone's text messages (SMS).",
            messagesOn, { messages.setEnabled(it) }, SettingsPage.MESSAGES
        )
    }
    FeatureRow(
        "Clipboard history", "Keep a searchable, pinnable history of what you copied, on this device only.",
        historyOn, { history.setEnabled(it) }, SettingsPage.CLIPBOARD_HISTORY
    )
}

private data class AppEntry(val packageName: String, val label: String)

private fun loadLaunchableApps(context: android.content.Context): List<AppEntry> {
    val pm = context.packageManager
    val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
    return pm.queryIntentActivities(launcher, 0)
        .map { AppEntry(it.activityInfo.packageName, it.loadLabel(pm).toString()) }
        .filter { it.packageName != context.packageName }
        .distinctBy { it.packageName }
        .sortedBy { it.label.lowercase() }
}

/** Settings → Notifications → Apps: pick which apps' notifications this phone forwards. All apps are
 *  on by default; see [NotificationForwardSettings]. */
@Composable
fun ColumnScope.NotificationAppsContent() {
    val context = LocalContext.current
    val settings = remember { NotificationForwardSettings.getInstance(context) }
    val blocked by settings.blocked.collectAsState()
    val apps by produceState<List<AppEntry>?>(null) { value = withContext(Dispatchers.IO) { loadLaunchableApps(context) } }
    var query by remember { mutableStateOf("") }

    val all = apps
    if (all == null) {
        Text("Loading apps…", style = MaterialTheme.typography.bodyMedium)
        return
    }
    val shown = if (query.isBlank()) all else all.filter { it.label.contains(query.trim(), ignoreCase = true) }

    OutlinedTextField(
        value = query,
        onValueChange = { query = it },
        label = { Text("Search apps") },
        singleLine = true,
        modifier = Modifier.fillMaxWidth()
    )
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            "${all.count { it.packageName !in blocked }} of ${all.size} apps forwarded",
            style = MaterialTheme.typography.bodySmall
        )
        TextButton(onClick = { settings.setAllAllowed() }, enabled = blocked.isNotEmpty()) { Text("Allow all") }
    }
    LazyColumn(modifier = Modifier.weight(1f).fillMaxWidth()) {
        items(shown, key = { it.packageName }) { app ->
            Row(
                modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                AppIcon(app.packageName)
                Text(
                    app.label,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f).padding(horizontal = 12.dp)
                )
                Switch(
                    checked = app.packageName !in blocked,
                    onCheckedChange = { settings.setAllowed(app.packageName, it) }
                )
            }
        }
    }
}

@Composable
private fun AppIcon(packageName: String) {
    val pm = LocalContext.current.packageManager
    val bitmap = remember(packageName) {
        runCatching { pm.getApplicationIcon(packageName).toBitmap(96, 96).asImageBitmap() }.getOrNull()
    }
    if (bitmap != null) {
        Image(bitmap = bitmap, contentDescription = null, modifier = Modifier.size(36.dp))
    } else {
        androidx.compose.foundation.layout.Spacer(Modifier.size(36.dp))
    }
}

/** Settings → Clipboard history: the on/off switch, search, copy back, pin, delete and clear. Device-local only. */
@Composable
fun ColumnScope.ClipboardHistoryContent(onCopy: (String) -> Unit) {
    val store = ClipboardHistoryStore.getInstance(LocalContext.current)
    val enabled by store.enabled.collectAsState()
    val entries by store.entries.collectAsState()
    var query by remember { mutableStateOf("") }
    var confirmClear by remember { mutableStateOf(false) }

    Text(
        "Stored only on this device, never sent to other devices or the relay. Turning it off on the Features page deletes it.",
        style = MaterialTheme.typography.bodySmall
    )
    if (!enabled) return
    OutlinedTextField(
        value = query, onValueChange = { query = it }, label = { Text("Search") },
        singleLine = true, modifier = Modifier.fillMaxWidth()
    )
    val shown = remember(entries, query) { store.filtered(query) }
    LazyColumn(modifier = Modifier.weight(1f).fillMaxWidth()) {
        items(shown, key = { it.id }) { entry ->
            Row(modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f).clickable { onCopy(entry.text) }) {
                    Text(entry.text, maxLines = 3, overflow = TextOverflow.Ellipsis)
                    Text(
                        (if (entry.remote) "From another device · " else "") +
                            android.text.format.DateUtils.getRelativeTimeSpanString(entry.date),
                        style = MaterialTheme.typography.bodySmall
                    )
                }
                TextButton(onClick = { store.togglePin(entry.id) }) { Text(if (entry.pinned) "Unpin" else "Pin") }
                TextButton(onClick = { store.remove(entry.id) }) { Text("Delete") }
            }
        }
    }
    TextButton(onClick = { confirmClear = true }, enabled = entries.isNotEmpty()) { Text("Clear all (${entries.size})") }
    if (confirmClear) {
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { confirmClear = false },
            title = { Text("Delete all clipboard history?") },
            text = { Text("This includes pinned items.") },
            confirmButton = { TextButton(onClick = { store.clear(); confirmClear = false }) { Text("Delete") } },
            dismissButton = { TextButton(onClick = { confirmClear = false }) { Text("Cancel") } }
        )
    }
}

/** Settings → Messages (opened from the ⋮ on the Features page): permissions and status. The on/off switch is on the Features page. */
@Composable
fun ColumnScope.MessagesSettingsContent() {
    val context = LocalContext.current
    val settings = remember { dev.vmd1.gossip.features.messages.MessagesSettings.getInstance(context) }
    val enabled by settings.enabled.collectAsState()
    val permissions = arrayOf(
        android.Manifest.permission.READ_SMS, android.Manifest.permission.SEND_SMS, android.Manifest.permission.READ_CONTACTS
    )
    fun smsGranted() = context.checkSelfPermission(android.Manifest.permission.READ_SMS) == android.content.pm.PackageManager.PERMISSION_GRANTED &&
        context.checkSelfPermission(android.Manifest.permission.SEND_SMS) == android.content.pm.PackageManager.PERMISSION_GRANTED
    var granted by remember { mutableStateOf(smsGranted()) }
    val launcher = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.RequestMultiplePermissions()
    ) { granted = smsGranted() }

    Text(
        "Your paired Mac can list conversations, read them and send texts through this phone. SMS only (no MMS or RCS). " +
            "Message text travels only over your encrypted Gossip connection.",
        style = MaterialTheme.typography.bodySmall
    )
    if (!enabled) {
        Text("Messages is switched off on the Features page.", style = MaterialTheme.typography.bodyMedium)
    } else if (!granted) {
        Text("Gossip needs permission to read and send SMS (and to read contacts so names show).", style = MaterialTheme.typography.bodyMedium)
        androidx.compose.material3.Button(onClick = { launcher.launch(permissions) }) { Text("Grant permissions") }
    } else {
        Text("Ready. Open Messages from the Gossip menu on your Mac.", style = MaterialTheme.typography.bodyMedium)
    }
}
