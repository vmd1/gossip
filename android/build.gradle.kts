plugins {
    id("com.android.application") version "8.7.3" apply false
    id("org.jetbrains.kotlin.android") version "2.0.21" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.0.21" apply false
    id("org.jetbrains.kotlin.plugin.serialization") version "2.0.21" apply false
    // Bytecode-rewrites calls against the vendored hidden-API stub classes
    // (features/hotspot's ITetheringConnector/TetheringManagerHidden etc.) to the real
    // framework classes at build time — see TetherHelper.kt's doc comment.
    id("dev.rikka.tools.refine") version "4.4.0" apply false
}
