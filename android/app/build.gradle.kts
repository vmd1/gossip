import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
    id("dev.rikka.tools.refine")
}

// Stable project signing key, so an APK built on any machine or on CI updates the app installed from any other
// in place (Android refuses an update signed with a different key). Found through environment variables (CI) or
// ~/.gossip-signing/gossip-android.{keystore,properties} (local; see scripts/signing.sh). Without either, builds
// fall back to the default debug keystore, so contributors can still build.
val gossipSigning: Map<String, String>? = run {
    val store = File(System.getProperty("user.home"), ".gossip-signing")
    val props = Properties().also { p ->
        File(store, "gossip-android.properties").takeIf { it.isFile }?.inputStream()?.use { p.load(it) }
    }
    fun setting(env: String, prop: String): String? = System.getenv(env)?.takeIf { it.isNotEmpty() } ?: props.getProperty(prop)
    val keystore = System.getenv("GOSSIP_ANDROID_KEYSTORE")?.takeIf { it.isNotEmpty() }
        ?: File(store, "gossip-android.keystore").takeIf { it.isFile }?.path
    val values = mapOf(
        "storeFile" to keystore,
        "storePassword" to setting("GOSSIP_ANDROID_KEYSTORE_PASSWORD", "storePassword"),
        "keyAlias" to setting("GOSSIP_ANDROID_KEY_ALIAS", "keyAlias"),
        "keyPassword" to setting("GOSSIP_ANDROID_KEY_PASSWORD", "keyPassword"),
    )
    if (values.values.all { it != null }) values.mapValues { it.value!! } else null
}

// ---- Rust protocol engine (desktop/core) -------------------------------------------------------------------------
// The Android build produces the native libraries and the generated Kotlin bindings with desktop/scripts/build-android.sh
// (needs the NDK, `cargo-ndk` and a Rust toolchain; see desktop/README.md). The task is skipped when its output is
// already there; `-PrebuildCore` forces it, and GOSSIP_CORE_ABIS=arm64-v8a limits it to the ABIs you need locally.
val gossipDesktopDir: File = rootProject.file("../desktop")
val gossipCoreOutput: File = File(gossipDesktopDir, "target/android")
val rustPath: String = listOf("${System.getProperty("user.home")}/.cargo/bin", "/opt/homebrew/opt/rustup/bin", System.getenv("PATH") ?: "")
    .joinToString(File.pathSeparator)

val buildGossipCore by tasks.registering(Exec::class) {
    description = "Builds libgossip_ffi.so (all ABIs) and the generated Kotlin bindings from desktop/core."
    workingDir = gossipDesktopDir
    environment("PATH", rustPath)
    commandLine("sh", "scripts/build-android.sh")
    onlyIf { project.hasProperty("rebuildCore") || !File(gossipCoreOutput, "kotlin").isDirectory }
}

// JVM unit tests load the engine through JNA from a host build of the same library.
val gossipCoreHostLibDir: File = File(gossipDesktopDir, "target/debug")
val buildGossipCoreHost by tasks.registering(Exec::class) {
    description = "Builds the host (desktop) libgossip_ffi for JVM unit tests."
    workingDir = gossipDesktopDir
    environment("PATH", rustPath)
    commandLine("cargo", "build", "-p", "gossip-ffi")
    onlyIf { project.hasProperty("rebuildCore") || listOf("libgossip_ffi.dylib", "libgossip_ffi.so").none { File(gossipCoreHostLibDir, it).isFile } }
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
        // versionCode stays 1 on purpose: Android refuses to install a lower versionCode over a higher one, so
        // stamping the release number into it would stop a local build from replacing a release APK. Only the
        // human-readable name carries the release number (set by the release workflow); local builds are "dev".
        versionCode = 1
        versionName = System.getenv("GOSSIP_RELEASE_NUMBER")?.takeIf { it.isNotBlank() } ?: "dev"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        gossipSigning?.let { k ->
            create("project") {
                storeFile = file(k.getValue("storeFile"))
                storePassword = k.getValue("storePassword")
                keyAlias = k.getValue("keyAlias")
                keyPassword = k.getValue("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            gossipSigning?.let { signingConfig = signingConfigs.getByName("project") }
        }
        debug {
            isMinifyEnabled = false
            gossipSigning?.let { signingConfig = signingConfigs.getByName("project") }
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
        buildConfig = true // BuildConfig.DEBUG gates the diagnostic logging (util/Log.kt)
    }

    sourceSets {
        getByName("main") {
            // The Rust protocol engine (desktop/core): libgossip_ffi.so per ABI and its generated Kotlin bindings, produced
            // by desktop/scripts/build-android.sh (see the buildGossipCore task below).
            jniLibs.srcDir(File(gossipCoreOutput, "jniLibs"))
            java.srcDir(File(gossipCoreOutput, "kotlin"))
        }
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

    // The generated Kotlin bindings for the Rust protocol engine call into libgossip_ffi.so through JNA.
    implementation("net.java.dev.jna:jna:5.17.0@aar")

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
    // The JVM flavour of JNA (the @aar above carries Android's native dispatcher, which a host JVM cannot load).
    testImplementation("net.java.dev.jna:jna:5.17.0")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:core:1.6.1")
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

// The engine must exist before anything compiles, and unit tests need its host build.
tasks.named("preBuild") { dependsOn(buildGossipCore) }
tasks.withType<Test>().configureEach {
    dependsOn(buildGossipCoreHost)
    systemProperty("jna.library.path", gossipCoreHostLibDir.absolutePath)
}
