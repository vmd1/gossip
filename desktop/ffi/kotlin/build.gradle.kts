// JVM harness that compiles the *generated* Kotlin bindings and runs them against the native library, so the
// Kotlin API is exercised in CI without an Android emulator. (The Android app consumes the same generated file
// plus per-ABI libgossip_ffi.so files; see desktop/README.md.)
plugins {
    kotlin("jvm") version "2.2.21"
}

repositories {
    mavenCentral()
}

dependencies {
    implementation("net.java.dev.jna:jna:5.17.0")
    testImplementation(kotlin("test"))
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

val nativeLibDir = providers.gradleProperty("nativeLibDir").orElse("${rootDir}/../../target/debug")

sourceSets {
    main {
        // `scripts/test-kotlin-bindings.sh` generates the bindings here.
        kotlin.srcDir("${rootDir}/../../target/gen/kotlin")
    }
}

tasks.test {
    useJUnitPlatform()
    systemProperty("jna.library.path", nativeLibDir.get())
    testLogging {
        events("passed", "failed")
        showStandardStreams = true
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
}
