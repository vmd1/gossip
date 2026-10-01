package dev.vmd1.gossip.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import dev.vmd1.gossip.features.settings.Feature
import dev.vmd1.gossip.features.settings.FeatureSettings

/**
 * The Settings page: setup actions (via [content]) followed by per-feature on/off switches for *this*
 * device (all on by default). Turning a feature off makes this device stop sending and receiving it
 * entirely — see [FeatureSettings].
 */
@Composable
fun SettingsScreen(
    settings: FeatureSettings,
    onBack: () -> Unit,
    /** Setup actions shown above the feature switches (pairing, permissions, ...). */
    content: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit = {}
) {
    val disabled by settings.disabled.collectAsState()
    Scaffold { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(24.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Text("Settings", style = MaterialTheme.typography.headlineMedium)
            content()
            Text("Features", style = MaterialTheme.typography.titleMedium)
            Text(
                "Turning a feature off stops this device from sending or receiving it at all. " +
                    "Your other devices keep their own settings.",
                style = MaterialTheme.typography.bodySmall
            )
            for (feature in Feature.values()) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(modifier = Modifier.weight(1f).padding(end = 12.dp)) {
                        Text(feature.title, style = MaterialTheme.typography.bodyLarge)
                        Text(feature.detail, style = MaterialTheme.typography.bodySmall)
                    }
                    Switch(
                        checked = feature !in disabled,
                        onCheckedChange = { settings.setEnabled(feature, it) }
                    )
                }
            }
            TextButton(onClick = onBack) { Text("Back") }
        }
    }
}
