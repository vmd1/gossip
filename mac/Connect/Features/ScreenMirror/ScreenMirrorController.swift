import Foundation
import Combine

/// Screen mirroring is just the installed `scrcpy` binary (https://github.com/Genymobile/scrcpy),
/// launched as a subprocess when the user clicks "Mirror Screen" and terminated on "Stop
/// Mirroring". It opens and owns its own window — Connect doesn't capture, decode, render, or
/// forward input itself; `scrcpy` already does all of that, well, against the phone over the
/// same local ADB tunnel that's already trusted by virtue of the on-device "Allow USB
/// debugging?" RSA key approval. `TransportManager` is only used separately (see `MenuBarView`)
/// to send the `screen.start`/`screen.stop` signaling messages so the Android app's UI can
/// reflect mirroring state — this controller works whether or not a Noise session is currently
/// connected, as long as `adb devices` shows the phone and `scrcpy` is installed.
final class ScreenMirrorController: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case mirroring
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private var process: Process?

    /// - Parameter serial: When known (e.g. resolved by `ADBWirelessPairing`
    ///   or an existing `adb devices -l` check in `MenuBarView`), every `adb`
    ///   command is targeted at this exact device via `-s <serial>` instead
    ///   of relying on `adb`'s single-device auto-detection.
    func start(serial: String? = nil) {
        // Retry after a failure must actually restart, not silently no-op — `.failed` is a
        // terminal state the user explicitly asked to leave via the Retry button, same as
        // `.idle`. Only genuinely in-flight states (`.starting`, `.mirroring`) should block
        // a fresh start.
        switch state {
        case .idle, .failed:
            break
        case .starting, .mirroring:
            return
        }
        state = .starting

        guard let scrcpyPath = Self.resolveScrcpyPath() else {
            state = .failed("scrcpy not found — install it with `brew install scrcpy`.")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: scrcpyPath)
        // scrcpy shells out to `adb` internally, and by default resolves it via its own
        // PATH search — which, under App Sandbox, finds and tries to exec a Homebrew-installed
        // `adb` outside the app's bundle/container. That's denied outright (confirmed via a
        // live sandbox violation: "deny(1) process-exec* /opt/homebrew/.../adb"), even though
        // launching `scrcpy` itself succeeds, since sandbox does permit exec'ing another
        // binary that's part of this same signed app bundle. Pointing scrcpy at our own
        // bundled `adb` (scrcpy's documented `ADB` env var override) keeps the whole process
        // tree inside the bundle and avoids the denial.
        // Same reasoning, for scrcpy's *other* external dependency: it `adb push`es its own
        // server component onto the phone at the start of every session, and by default
        // resolves that file's path relative to its own compiled-in Homebrew install prefix
        // (confirmed live: "adb: error: opening /opt/homebrew/Cellar/scrcpy/...") — outside
        // the bundle, so the same sandbox denial pattern applies once `adb push` tries to open
        // it. `SCRCPY_SERVER_PATH` is scrcpy's documented override; the bundled copy is at
        // `Contents/Resources/bin/scrcpy-server` (added in `project.yml`, alongside `adb`/`scrcpy`
        // themselves).
        var environment = ProcessInfo.processInfo.environment
        if let adbPath = ADBClient.resolveADBPath() {
            environment["ADB"] = adbPath
        }
        if let serverPath = Bundle.main.url(forResource: "scrcpy-server", withExtension: nil, subdirectory: "bin") {
            environment["SCRCPY_SERVER_PATH"] = serverPath.path
        }
        // Same idea, for scrcpy's window/dock icon (cosmetic only — confirmed harmless to
        // mirroring itself, but noisy: "ERROR: Could not open icon image:
        // /opt/homebrew/Cellar/scrcpy/.../scrcpy.png" on every launch and disconnect).
        if let iconDir = Bundle.main.url(forResource: "icons", withExtension: nil, subdirectory: "bin") {
            environment["SCRCPY_ICON_DIR"] = iconDir.path
        }
        process.environment = environment
        if let serial {
            process.arguments = ["-s", serial]
        }

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        var stderrData = Data()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            stderrData.append(handle.availableData)
        }

        process.terminationHandler = { [weak self] terminatedProcess in
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self, self.process === terminatedProcess else { return }
                self.process = nil
                if terminatedProcess.terminationStatus != 0, case .mirroring = self.state {
                    // Exited unexpectedly (e.g. device unplugged) rather than via
                    // an explicit Stop Mirroring click, which sets state to .idle
                    // itself before terminating the process.
                    let message = String(data: stderrData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    self.state = .failed(message?.isEmpty == false ? message! : "scrcpy exited unexpectedly")
                } else if terminatedProcess.terminationStatus != 0, case .starting = self.state {
                    let message = String(data: stderrData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    self.state = .failed(message?.isEmpty == false ? message! : "scrcpy failed to start")
                }
            }
        }

        do {
            try process.run()
            self.process = process
            // scrcpy has no "ready" signal on stdout we need to parse — its own
            // window appearing IS the ready signal. Treat launch-without-immediate-
            // exit as success.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.process === process else { return }
                if case .starting = self.state {
                    self.state = .mirroring
                }
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        state = .idle
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
    }

    /// Prefers the copy bundled inside the app (`Contents/Resources/bin/scrcpy`, added in
    /// `project.yml`) so end users don't need to `brew install scrcpy` separately; falls
    /// back to common Homebrew/manual install locations and finally a `PATH` lookup via
    /// `env`, which mainly matters for local dev before the bundled resource is present —
    /// same approach as `ADBClient.resolveADBPath()`.
    private static func resolveScrcpyPath() -> String? {
        if let bundled = Bundle.main.url(forResource: "scrcpy", withExtension: nil, subdirectory: "bin"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled.path
        }

        let candidates = [
            "/opt/homebrew/bin/scrcpy",
            "/usr/local/bin/scrcpy",
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "scrcpy"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
                return path
            }
        } catch {
            return nil
        }
        return nil
    }
}
