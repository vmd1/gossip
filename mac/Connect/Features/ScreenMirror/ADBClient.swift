import Foundation

/// Errors surfaced by `ADBClient`.
enum ADBError: Error, LocalizedError {
    case adbNotFound
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .adbNotFound: return "adb was not found."
        case .processFailed(let msg): return "adb command failed: \(msg)"
        }
    }
}

/// Thin wrapper around locating and shelling out to `adb`. Screen mirroring itself is
/// entirely `scrcpy`'s job (capture, render, and input forwarding — see
/// `ScreenMirrorController`); this only covers the pieces `scrcpy` doesn't do: resolving
/// where `adb` lives, and checking for an already-authorized device before launching
/// `scrcpy` (also used by `ADBWirelessPairing` for its own `adb pair`/`adb connect` calls).
enum ADBClient {
    /// Resolves the path to the `adb` binary. Prefers the copy bundled inside the app
    /// (`Contents/Resources/bin/adb`, added in `project.yml`) so end users don't need
    /// Android Platform Tools installed separately; falls back to common Homebrew/manual
    /// install locations and finally a `PATH` lookup, which mainly matters for local dev
    /// before the bundled resource is present.
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

    /// Runs `adb <args>` synchronously via the resolved `adb` path, returning stdout and
    /// throwing on a nonzero exit code. Meant for short-lived, quick commands (device
    /// listing, `mdns services`, `pair`/`connect`) — mirroring itself never goes through
    /// this, `scrcpy` shells out to `adb` internally on its own.
    @discardableResult
    static func run(_ args: [String]) throws -> Data {
        guard let adbPath = resolveADBPath() else { throw ADBError.adbNotFound }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = args
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
}
