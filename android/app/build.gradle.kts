plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
    id("dev.rikka.tools.refine")
}

android {
    namespace = "com.connect"
    // 36 (Android 16), not 34: needed at compile time only, for `@RefineAs(TetheringManager
    // .class)` in the vendored features/hotspot stub — that class isn't in the public SDK
    // jar until API 36. minSdk/targetSdk are unchanged; this doesn't affect runtime
    // behavior on older devices, only what's resolvable while compiling.
    compileSdk = 36

    defaultConfig {
        applicationId = "com.connect"
        minSdk = 29
        targetSdk = 34
        versionCode = 1
        versionName = "0.1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
        debug {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
}

dependencies {
    // Core / Kotlin
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.6")
    implementation("androidx.lifecycle:lifecycle-service:2.8.6")
    implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.8.6")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.6")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")

    // Compose
    implementation(platform("androidx.compose:compose-bom:2024.10.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.9.2")
    debugImplementation("androidx.compose.ui:ui-tooling")

    // Security / crypto
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    implementation("com.google.crypto.tink:tink-android:1.15.0")
    implementation("org.bouncycastle:bcprov-jdk18on:1.78.1")

    // Camera / QR
    implementation("androidx.camera:camera-core:1.3.4")
    implementation("androidx.camera:camera-camera2:1.3.4")
    implementation("androidx.camera:camera-lifecycle:1.3.4")
    implementation("androidx.camera:camera-view:1.3.4")
    implementation("com.google.mlkit:barcode-scanning:17.3.0")
    // Pure-Java QR *encoding* (no Android dependency, unlike the scanning stack above) —
    // used to render this device's own pairing QR when it's the one being scanned rather
    // than scanning. See features/pairing/... QR generation.
    implementation("com.google.zxing:core:3.5.3")

    // Shizuku (Instant Hotspot, background clipboard reads): obtains a shell-UID Binder to
    // hidden system services — see features/hotspot/{TetherHelper,ShizukuManager}.kt and
    // features/clipboard/ShizukuClipboardReader.kt.
    implementation("dev.rikka.shizuku:api:13.1.5")
    implementation("dev.rikka.shizuku:provider:13.1.5")
    // Lifts Android's non-SDK-interface reflection restriction for the one raw hidden call
    // ShizukuClipboardReader makes (android.content.IClipboard) — a plain reflection-based
    // call, unlike the tethering path above which needs the heavier Refine/module-split
    // machinery because IClipboard doesn't need to be *statically* linked, only reflected
    // into once at read time.
    implementation("org.lsposed.hiddenapibypass:hiddenapibypass:6.1")
    // Hidden-API stubs (ITetheringConnector/TetheringManagerHidden/etc) — compileOnly so
    // none of this module's own classes are packaged into the app's dex output; the
    // `dev.rikka.tools.refine` plugin above rewrites calls against them to the real
    // framework classes at compile time. See system-api-stubs/build.gradle.kts.
    compileOnly(project(":system-api-stubs"))

    // Testing
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.6.1")
}
