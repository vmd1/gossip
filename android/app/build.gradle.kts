plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
    id("dev.rikka.tools.refine")
}

android {
    namespace = "dev.vmd1.gossip"
    // 36 (Android 16), not 34: needed at compile time only, for `@RefineAs(TetheringManager
    // .class)` in the vendored features/hotspot stub — that class isn't in the public SDK
    // jar until API 36. minSdk/targetSdk are unchanged; this doesn't affect runtime
    // behavior on older devices, only what's resolvable while compiling.
    compileSdk = 36

    defaultConfig {
        applicationId = "dev.vmd1.gossip"
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
            // Signature files from signed dependency jars (bcprov-jdk18on) — APK
            // packaging never verifies jar signatures, so these are dead weight in the
            // APK. NOTE: this alone does NOT fix the `SecurityException: SHA-256 digest
            // error` that bcprov triggers in `testDebugUnitTest` — that's a separate,
            // host-JVM-only issue fixed near the `stripBcprovSignature` task below.
            excludes += "META-INF/*.SF"
            excludes += "META-INF/*.DSA"
            excludes += "META-INF/*.RSA"
        }
    }
}

// Rebuilds bcprov-jdk18on with its signature metadata stripped (same class bytes) — see
// the `testImplementation(files(stripBcprovSignature))` comment below for why this exists.
val stripBcprovSignature by tasks.registering(Jar::class) {
    from(zipTree(configurations.detachedConfiguration(dependencies.create("org.bouncycastle:bcprov-jdk18on:1.78.1")).singleFile)) {
        exclude("META-INF/*.SF", "META-INF/*.RSA", "META-INF/*.DSA")
    }
    archiveFileName.set("bcprov-jdk18on-1.78.1-unsigned.jar")
    destinationDirectory.set(layout.buildDirectory.dir("bcprov-unsigned"))
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

    // bcprov-jdk18on (used by NoiseSession.kt's Noise_IK handshake) is a signed jar. The
    // `dev.rikka.tools.refine` plugin applied above installs an ASM classes-transform
    // (`transformDebug(UnitTest)?ClassesWithAsm`) that runs over *every* class on this
    // module's classpath — including third-party dependency jars, not just this project's
    // own classes — looking for calls to `@RefineAs`-annotated stubs. Re-emitting bcprov's
    // class files through that pipeline (even though nothing in bcprov needs rewriting)
    // invalidates the jar's per-entry SHA-256 digests recorded in its signed manifest, so
    // the plain JVM unit-test classpath (unlike the on-device APK classpath, which never
    // signature-verifies jars at all) throws `SecurityException: SHA-256 digest error` the
    // instant a BC class loads. Confirmed via `jarsigner -verify`: the pristine dependency
    // jar verifies cleanly; the specific copy under this module's Gradle transforms cache
    // does not. Reproduces identically in CI on a clean checkout (not local cache
    // corruption — see the Android workflow run for commit b6c2cef) and is unrelated to
    // the Noise handshake logic itself or to any change in this session.
    //
    // Fix: exclude bcprov from the test configurations' transitively-inherited copy (the
    // one the Refine transform corrupts) and supply an unsigned rebuild — same class
    // bytes, signature metadata stripped so there's nothing left for `JarFile` to
    // (mis)verify — in its place, test-only.
    testImplementation(files(stripBcprovSignature))
}

configurations.matching { it.name == "testCompileClasspath" || it.name == "testRuntimeClasspath" }.configureEach {
    exclude(group = "org.bouncycastle", module = "bcprov-jdk18on")
}
