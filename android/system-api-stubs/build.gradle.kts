// Java-only hidden-API stub module for Instant Hotspot (see features/hotspot/TetherHelper.kt).
// `compileOnly`-referenced from `app` — never packaged into the app's own dex output.
// The `dev.rikka.tools.refine` Gradle *plugin* (the bytecode-rewriting transform) is
// applied only in `app`, the module that actually calls these classes — this module just
// needs the annotation itself, at compile time, on `TetheringManagerHidden`'s
// `@RefineAs(TetheringManager.class)`. See RikkaApps/HiddenApiRefinePlugin's README.
plugins {
    id("com.android.library")
}

android {
    namespace = "com.connect.systemapistubs"
    compileSdk = 36

    defaultConfig {
        minSdk = 29
    }

    buildFeatures {
        aidl = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    compileOnly("androidx.annotation:annotation:1.8.2")
    compileOnly("dev.rikka.tools.refine:annotation:4.4.0")
    annotationProcessor("dev.rikka.tools.refine:annotation-processor:4.4.0")
}
