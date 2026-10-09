# Building and signing

How to build, test and sign Gossip, and how releases are made.

## Prerequisites

- **Both apps: a Rust toolchain.** The wire protocol (Noise handshake, framing, signatures, mesh routing, trust) lives in the Rust core in [`desktop/`](../desktop), which both apps call through generated bindings
  - `brew install rustup && rustup default stable` (or [rustup.rs](https://rustup.rs)); `desktop/rust-toolchain.toml` pins the channel
- **Mac app**
  - a recent Xcode (CI uses the latest stable; macOS 14 or newer is the deployment target)
  - [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- **Android app**
  - JDK 17
  - the Android SDK (the project compiles against API 36) and an NDK (r26 or newer; `sdkmanager "ndk;27.3.13750724"`)
  - Rust Android targets and cargo-ndk: `rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android i686-linux-android` and `cargo install cargo-ndk`
- **Optional:** `adb` (Android SDK Platform Tools) for installing builds and running the device end-to-end tests

## Build

- **Mac**
  - build the protocol engine as a Swift package first (re-run after changing anything under `desktop/`), then generate the Xcode project (it is not checked in) and build in Xcode or from the command line:

```bash
cd mac
scripts/build-core.sh        # this machine's architecture; add --universal for arm64 + x86_64
xcodegen generate
xcodebuild -project Gossip.xcodeproj -scheme Gossip -configuration Release -destination 'platform=macOS' build
```

  - the output is `Gossip.app` (it contains the Device Mirroring launcher app)
  - re-run `xcodegen generate` after adding or removing files or editing `project.yml`
- **Android**

```bash
cd android
./gradlew assembleDebug      # app/build/outputs/apk/debug/app-debug.apk
```

  - Gradle builds the protocol engine itself (`desktop/scripts/build-android.sh`, all four ABIs) the first time and skips it while `desktop/target/android` exists; `-PrebuildCore` forces a rebuild
  - for quick local builds set `GOSSIP_CORE_ABIS=arm64-v8a` to build just the ABI your device needs

## Test

- **Rust core and bindings:** `cd desktop && cargo test`; see [`desktop/README.md`](../desktop/README.md) for the interop tests against the apps' own code and for running the suite on a device
- **Mac unit tests**
  - `xcodebuild test -project Gossip.xcodeproj -scheme Gossip -destination 'platform=macOS'`
  - the app is the test host, so it launches during the run (with throwaway identity and trust stores, never the real Keychain items), and redirect the output to a file because it is long
- **Android unit tests:** `cd android && ./gradlew testDebugUnitTest` (this builds a host copy of the protocol engine with `cargo build -p gossip-ffi` the first time)
- **Device end-to-end (Universal Control):** `mac/scripts/run-tablet-e2e.sh [adb-serial] [scenario...]`
  - drives a real device with the same protocol code the Mac app uses and asserts on logcat and `dumpsys input`
  - needs the debug APK installed, Gossip's service running and Shizuku running on the device
  - **quit the Mac app first** — it keeps its own session to the device and would take over
  - scenarios: `basic`, `idle`, `smooth`, `slow`, `hold`, `locate`, `nav`, `recross`, `drift`
  - set `UC_HOST=<device LAN IP>` to connect directly over Wi-Fi instead of through an adb tunnel

## Signing

- why it matters
  - macOS ties Accessibility and Input Monitoring grants to the app's code signature
  - an ad-hoc signature changes on every build, so the grants would reset every time
  - Android refuses to install an update signed with a different key than the installed app
  - so every build, local and CI, is signed with one stable key per platform
- **Mac: the `gossip.vmd1.dev` identity**
  - it is a self-signed code-signing certificate, not an Apple Developer ID, so builds are not notarized and Gatekeeper still blocks a downloaded copy (users choose **Open Anyway**)
  - create and install it once on your machine:

```bash
cd mac
scripts/create-signing-cert.sh
xcodegen generate
```

  - the script
    - creates the key in `~/.gossip-signing/` (a `.p12` and its random password), unless it already exists
    - imports it into your login keychain and marks it trusted for code signing in your account, which recent macOS needs before `codesign` will use it (expect one password prompt)
    - writes `mac/Config/Signing.local.xcconfig` (git-ignored) so Debug and Release builds use it
  - `--generate-only` creates the files without touching your keychain
  - without the local file, builds fall back to ad-hoc signing and work, but permission grants reset on each build
  - Debug builds have Hardened Runtime switched off so the unit-test host can load its test bundle with this team-less identity; Release keeps it
- **Android: one project key**
  - Gradle (`android/app/build.gradle.kts`) signs with the project key when it finds one, and otherwise falls back to the default debug keystore
    - CI: environment variables `GOSSIP_ANDROID_KEYSTORE`, `GOSSIP_ANDROID_KEYSTORE_PASSWORD`, `GOSSIP_ANDROID_KEY_ALIAS`, `GOSSIP_ANDROID_KEY_PASSWORD`
    - local: `~/.gossip-signing/gossip-android.keystore` and `gossip-android.properties`
  - reuse the keystore your installed apps are already signed with, so they keep updating in place:

```bash
android/scripts/signing.sh adopt     # copies ~/.android/debug.keystore into ~/.gossip-signing/
```

- **Back up `~/.gossip-signing/`** and never commit anything in it (`.gitignore` blocks `*.p12`, `*.keystore` and `*.password`)
  - GitHub secrets cannot be read back, and losing a key means a new identity: everyone re-grants permissions once, and Android devices must uninstall before installing a build with the new key

## CI and releases

- **Pull requests** (`mac.yml`, `android.yml`)
  - build and run the unit tests; the Mac job builds unsigned, the Android job uses the default debug key
  - they upload a debug build as an artifact; those artifacts are not update-compatible with release builds
- **Releases** (`release.yml`)
  - runs when the `VERSION` file changes on `main` (a merge that leaves it alone ships nothing), or manually to retry the current version
  - jobs
    - `version` — reads `VERSION` and refuses a version whose tag already exists
    - `android-release` — builds and signs the APK, then checks it was signed by the expected certificate
    - `mac-release` — builds and signs `Gossip.app`, then checks the signature and version
    - `publish` — creates the GitHub Release (only on `main`)
  - versioning: `VERSION` holds `MAJOR.MINOR` (e.g. `1.1`); tag `v1.1`, title `Gossip 1.1 (YYYY-MM-DD)`
    - bump the minor for a normal release and the major for a wire-protocol break: every device must run the same version
    - `version-check.yml` runs on every pull request: `VERSION` must be well formed and never go down, and a PR that changes `schema/` must raise the major above the one on `main` unless it carries the `schema-compatible` label (for edits that don't change the wire format, such as wording fixes)
    - to release: open a PR that edits `VERSION`, merge it to `main`
  - versions: the version becomes Android's `versionName` and the Mac app's version (`MARKETING_VERSION`); local builds show `dev` on Android and `1.0` on the Mac
    - Android's `versionCode` stays 1 on purpose, so a local build can still replace a release APK
- **Where the signing keys live (public repo)**
  - in a GitHub **environment** named `release`, restricted to the `main` branch, so only jobs running on `main` that declare `environment: release` can read them
  - pull-request workflows, fork PRs and feature branches cannot
  - secrets: `SIGNING_CERT_P12_BASE64`, `SIGNING_CERT_PASSWORD`, `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`
  - load or rotate them with `mac/scripts/set-ci-signing-secrets.sh` and `android/scripts/signing.sh upload` (needs `gh` with admin rights on the repo)
  - the workflow imports the Mac key into a throwaway keychain and deletes both keys when the job ends
  - anyone who can push to `main` can change the workflow, so consider branch protection on `main`

## Contributing

- development happens on `dev`: open pull requests against it; merging to `main` ships nothing by itself; a release is cut by bumping `VERSION` (see above)
- the Mac and Android apps share their protocol engine, the Rust core in [`desktop/`](../desktop); the rest (UI, sockets, OS integration, feature managers) is separate — keep them in sync through [`schema/message-types.md`](../schema/message-types.md)
  - any change to what a message carries, when it is sent or how it is handled updates that file in the same change
  - handlers must be idempotent, and messages that configure persistent state need a resync, so a dropped message heals itself
- see [architecture](architecture.md), the [wire protocol](wire-protocol.md) and the [ADRs](adr) for the design

## End-to-end test against an Android emulator

`mac/scripts/e2e-emulator.sh [avd]` runs the Mac transport against the Android app on an emulator (headless if none is
booted): QR pairing, nested-Unicode and 1 MiB payloads, 3 MiB raw frames both ways, feature gating, a 70 s heartbeat
soak, reconnect without a prompt, and revocation. It never touches a real phone or the Mac app's Keychain data.
