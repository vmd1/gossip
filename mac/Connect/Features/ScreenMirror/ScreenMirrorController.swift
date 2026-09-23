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

    func start() {
        guard case .idle = state else { return }
        state = .starting

        guard let scrcpyPath = Self.resolveScrcpyPath() else {
            state = .failed("scrcpy not found on PATH — install it with `brew install scrcpy`.")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: scrcpyPath)

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

    /// Checks common Homebrew/manual install locations first, then falls back
    /// to a `PATH` lookup via `env` — same approach as resolving `adb`.
    private static func resolveScrcpyPath() -> String? {
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
