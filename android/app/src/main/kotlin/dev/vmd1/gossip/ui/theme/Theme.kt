package dev.vmd1.gossip.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

/** Apple's system blue — see `docs/design-system.md` for why this is the shared accent
 *  reference point across both platforms (it's also SwiftUI's default macOS accent). */
val ConnectBlue = Color(0xFF0A84FF)

private val LightColors = lightColorScheme(primary = ConnectBlue)
private val DarkColors = darkColorScheme(primary = ConnectBlue)

/** Wraps a screen in a Material3 [MaterialTheme] seeded from [ConnectBlue] instead of
 *  Compose's un-seeded default (an unrelated purple with no connection to this app), per
 *  `docs/design-system.md`'s Phase 6 design-system pass. Automatically follows the device's
 *  light/dark setting, same as every other well-behaved Android app — there's no separate
 *  "app dark mode" toggle to build. */
@Composable
fun ConnectTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = if (isSystemInDarkTheme()) DarkColors else LightColors,
        content = content
    )
}
