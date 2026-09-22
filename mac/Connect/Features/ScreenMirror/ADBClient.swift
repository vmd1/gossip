import Foundation

/// Errors surfaced by `ADBClient`.
enum ADBError: Error, LocalizedError {
    case adbNotFound
    case processFailed(String)
    case noDeviceConnected
    case unexpectedOutput(String)

    var errorDescription: String? {
        switch self {
        case .adbNotFound: return "adb was not found on PATH."
        case .processFailed(let msg): return "adb command failed: \(msg)"
        case .noDeviceConnected: return "No Android device is connected via adb."
        case .unexpectedOutput(let msg): return "Unexpected adb output: \(msg)"
        }
    }
}

/// Thin wrapper around shelling out to `adb` (via `Process`) for everything
/// screen mirroring needs: confirming a device is attached, resolving its
/// screen resolution, streaming a raw H.264 capture, and injecting input
/// events. `adb` is assumed to already be on PATH (confirmed present on the
/// dev machine for this unit); bundling a copy of `adb`/`platform-tools` into
/// the app bundle so end users don't need Android Platform Tools installed
/// separately is a packaging concern noted as a follow-up, not part of this
/// unit.
///
/// Nothing here touches `TransportManager`/`MessageRouter` or Noise at all —
/// this is a deliberately separate subsystem that talks to the phone over a
/// local ADB tunnel, which is already trusted by virtue of the user having
/// approved the on-device "Allow USB debugging?" RSA key prompt. See this
/// unit's PR description for the full rationale.
final class ADBClient {
    /// Resolves the path to the `adb` binary. Prefers the copy bundled
    /// inside the app (`Contents/Resources/bin/adb`, added in `project.yml`)
    /// so end users don't need Android Platform Tools installed separately;
    /// falls back to common Homebrew/manual install locations and finally a
    /// `PATH` lookup, which mainly matters for local dev before the bundled
    /// resource is present (e.g. running via `swift build` rather than the
    /// full app bundle).
    static func resolveADBPath() -> String? {
        if let bundled = Bundle.main.url(forResource: "adb", withExtension: nil, subdirectory: "bin"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled.path
        }

        let candidates = [
            "/opt/homebrew/bin/adb",
            "/opt/homebrew/share/android-commandlinetools/platform-tools/adb",
            "/usr/local/bin/adb",
            "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb",
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "adb"]
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

    let adbPath: String
    /// When set, every command is targeted at this specific device serial
    /// via `adb -s <serial> ...` rather than relying on `adb`'s own
    /// single-device auto-detection — set once `ADBWirelessPairing` (or an
    /// already-connected `adb devices -l`) has resolved an exact serial.
    let serial: String?

    init?(serial: String? = nil) {
        guard let path = ADBClient.resolveADBPath() else { return nil }
        self.adbPath = path
        self.serial = serial
    }

    /// Prepends `-s <serial>` to `args` when a specific device is targeted.
    private func withSerial(_ args: [String]) -> [String] {
        guard let serial else { return args }
        return ["-s", serial] + args
    }

    /// Runs `adb <args>` synchronously, returning stdout and throwing on a
    /// nonzero exit code. Meant for short-lived, quick commands (device
    /// checks, `wm size`, `input ...`) — not for the long-lived capture
    /// stream, which uses `startH264Capture` instead.
    @discardableResult
    func run(_ args: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = withSerial(args)
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errString = String(data: errData, encoding: .utf8) ?? "unknown error"
            throw ADBError.processFailed(errString)
        }
        return outData
    }

    /// True if `adb devices` lists at least one device in the `device`
    /// (fully authorized/ready) state — as opposed to `unauthorized` or
    /// `offline`.
    func hasConnectedDevice() throws -> Bool {
        let data = try run(["devices"])
        let text = String(data: data, encoding: .utf8) ?? ""
        return text
            .split(separator: "\n")
            .dropFirst() // "List of devices attached"
            .contains { $0.contains("\tdevice") }
    }

    /// Parses `adb shell wm size` (e.g. "Physical size: 1080x2340", or an
    /// "Override size: ..." line if the device has a forced display size)
    /// into `(width, height)` device pixels.
    func screenSize() throws -> (width: Int, height: Int) {
        let data = try run(["shell", "wm", "size"])
        guard let text = String(data: data, encoding: .utf8) else {
            throw ADBError.unexpectedOutput("non-utf8 output from wm size")
        }
        let lines = text.split(separator: "\n")
        let line = lines.first { $0.contains("Override size") }
            ?? lines.first { $0.contains("Physical size") }
        guard let line, let colonIndex = line.firstIndex(of: ":") else {
            throw ADBError.unexpectedOutput(text)
        }
        let dims = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
        let parts = dims.split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else {
            throw ADBError.unexpectedOutput(text)
        }
        return (w, h)
    }

    // MARK: - Input injection (control channel; identical for both capture approaches)
    //
    // Each of these shells out synchronously (`Process.waitUntilExit`), so
    // they're dispatched onto a background queue rather than run inline —
    // callers (event monitors) invoke these from the main thread and must
    // not block on an `adb` round-trip.

    private let inputQueue = DispatchQueue(label: "com.connect.app.adbclient.input", qos: .userInteractive)

    func tap(x: Int, y: Int) {
        inputQueue.async { [self] in _ = try? run(["shell", "input", "tap", "\(x)", "\(y)"]) }
    }

    func swipe(x1: Int, y1: Int, x2: Int, y2: Int, durationMs: Int = 100) {
        inputQueue.async { [self] in _ = try? run(["shell", "input", "swipe", "\(x1)", "\(y1)", "\(x2)", "\(y2)", "\(durationMs)"]) }
    }

    func keyevent(_ code: Int) {
        inputQueue.async { [self] in _ = try? run(["shell", "input", "keyevent", "\(code)"]) }
    }

    /// `adb shell input text` only accepts a single whitespace-escaped
    /// argument; good enough for v1 (ASCII, no IME composition).
    func text(_ string: String) {
        let escaped = string.replacingOccurrences(of: " ", with: "%s")
        inputQueue.async { [self] in _ = try? run(["shell", "input", "text", escaped]) }
    }

    // MARK: - Capture (approach (b): `adb exec-out screenrecord`)

    /// Starts `adb exec-out screenrecord --output-format=h264 -`, streaming
    /// the raw H.264 Annex-B elementary stream as it's produced. This is the
    /// "reduced but real" v1 capture mechanism documented in the unit's PR:
    /// simpler and more reliable to stand up than vendoring/reimplementing
    /// scrcpy's on-device Java capture server, at the cost of `screenrecord`'s
    /// own latency/overhead (it's designed for bug-report recording, not
    /// low-latency mirroring) and its default 180s time limit — this method
    /// passes `--time-limit 0` to lift that, and the caller
    /// (`ScreenMirrorController`) transparently restarts the process if it
    /// still terminates.
    ///
    /// `onData` fires on the pipe's readability-handler queue (not main).
    func startH264Capture(
        size: (width: Int, height: Int)? = nil,
        bitRate: Int = 8_000_000,
        onData: @escaping (Data) -> Void,
        onTermination: @escaping (Int32) -> Void
    ) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)

        var args = ["exec-out", "screenrecord", "--output-format=h264"]
        if let size {
            args += ["--size", "\(size.width)x\(size.height)"]
        }
        args += ["--bit-rate", "\(bitRate)", "--time-limit", "0", "-"]
        process.arguments = withSerial(args)

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe() // discarded; screenrecord logs nothing useful to stderr here

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            onData(data)
        }
        process.terminationHandler = { proc in
            stdout.fileHandleForReading.readabilityHandler = nil
            onTermination(proc.terminationStatus)
        }
        try process.run()
        return process
    }
}
