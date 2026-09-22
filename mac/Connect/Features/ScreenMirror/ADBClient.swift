import Foundation
import Network
import Darwin

/// Errors surfaced by `ADBClient`.
enum ADBError: Error, LocalizedError {
    case adbNotFound
    case processFailed(String)
    case noDeviceConnected
    case unexpectedOutput(String)
    case serverJarMissing
    case portUnavailable
    case socketConnectFailed(String)

    var errorDescription: String? {
        switch self {
        case .adbNotFound: return "adb was not found on PATH."
        case .processFailed(let msg): return "adb command failed: \(msg)"
        case .noDeviceConnected: return "No Android device is connected via adb."
        case .unexpectedOutput(let msg): return "Unexpected adb output: \(msg)"
        case .serverJarMissing: return "Vendored scrcpy-server.jar not found (expected at android/screen-server/scrcpy-server.jar)."
        case .portUnavailable: return "Could not reserve a local TCP port for the adb forward."
        case .socketConnectFailed(let msg): return "Could not connect to the forwarded scrcpy socket: \(msg)"
        }
    }
}

/// Handle for a live capture session started by `startScrcpyCapture`: the
/// on-device `app_process`-launched scrcpy server plus the Mac-side `adb
/// forward` redirection and the raw TCP socket reading the forwarded H.264
/// stream. `stop()` tears down all three; letting the handle deinit without
/// calling `stop()` leaks the forward and (until the USB connection notices)
/// the on-device process, so callers must always call it.
final class ScreenCaptureSession {
    private let process: Process
    private let connection: NWConnection
    private let adbPath: String
    private let forwardPort: UInt16
    private var isStopped = false
    private let stopLock = NSLock()

    fileprivate init(process: Process, connection: NWConnection, adbPath: String, forwardPort: UInt16) {
        self.process = process
        self.connection = connection
        self.adbPath = adbPath
        self.forwardPort = forwardPort
    }

    func stop() {
        stopLock.lock()
        defer { stopLock.unlock() }
        guard !isStopped else { return }
        isStopped = true

        connection.stateUpdateHandler = nil
        connection.cancel()

        process.terminationHandler = nil
        if process.isRunning {
            process.terminate()
        }

        // Best-effort cleanup: drop the host-side forward. Terminating the
        // local `adb shell` process closes its USB/adb transport connection,
        // which ends the corresponding remote shell (and the `app_process`
        // it launched) on the device side — the same mechanism the earlier
        // `adb exec-out screenrecord` approach relied on.
        let remove = Process()
        remove.executableURL = URL(fileURLWithPath: adbPath)
        remove.arguments = ["forward", "--remove", "tcp:\(forwardPort)"]
        remove.standardOutput = Pipe()
        remove.standardError = Pipe()
        try? remove.run()
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
    /// Resolves the path to the `adb` binary. Checks common Homebrew/manual
    /// install locations first, then falls back to a `PATH` lookup via `env`.
    static func resolveADBPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/adb",
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

    init?() {
        guard let path = ADBClient.resolveADBPath() else { return nil }
        self.adbPath = path
    }

    /// Runs `adb <args>` synchronously, returning stdout and throwing on a
    /// nonzero exit code. Meant for short-lived, quick commands (device
    /// checks, `wm size`, `input ...`) — not for the long-lived capture
    /// stream, which uses `startScrcpyCapture` instead.
    @discardableResult
    func run(_ args: [String]) throws -> Data {
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

    // MARK: - Capture (approach (a): vendored scrcpy on-device server)
    //
    // See android/screen-server/README.md for the full protocol writeup and
    // the dalvik-cache fix. Summary: push Genymobile/scrcpy's real
    // `scrcpy-server.jar` (v4.1, Apache 2.0) to `/data/local/tmp`, launch it
    // via `adb shell CLASSPATH=<jar> app_process / com.genymobile.scrcpy.Server
    // <version> <options...>` with `raw_stream=true` (scrcpy's own
    // documented "standalone server" mode — see their doc/develop.md), which
    // makes it emit a bare Annex-B H.264 elementary stream with none of
    // scrcpy's own frame-meta/device-meta framing. That means `H264Decoder`
    // — written against `screenrecord`'s raw Annex-B output — needs no
    // changes at all; only the transport (forwarded TCP socket instead of an
    // `adb exec-out` pipe) is new.

    private static let deviceServerPath = "/data/local/tmp/connect-scrcpy-server.jar"
    private static let serverVersion = "4.1"
    /// scrcpy's on-device server names its local abstract socket
    /// `"scrcpy"` when launched with no `scid` param (`scid` defaults to
    /// -1 -> `SOCKET_NAME_PREFIX` alone, no `_%08x` suffix — see
    /// `DesktopConnection.getSocketName` in scrcpy's server source). We
    /// don't pass `scid`, so this must match that literal default exactly;
    /// it is *not* an arbitrary name we get to choose.
    private static let deviceSocketName = "scrcpy"

    /// Locates the vendored `android/screen-server/scrcpy-server.jar`
    /// relative to this source file, so pushing it works from an
    /// `xcodebuild`/Xcode build against a full repo checkout without needing
    /// a "Copy Bundle Resources" phase. Bundling the jar inside `Connect.app`
    /// itself (for distribution to users who don't have the repo checked
    /// out) is a packaging follow-up — same category as the `adb`-on-PATH
    /// assumption noted above.
    private static func vendoredServerJarURL() -> URL? {
        // This file lives at mac/Connect/Features/ScreenMirror/ADBClient.swift.
        let sourceFile = URL(fileURLWithPath: #filePath)
        let repoRoot = sourceFile
            .deletingLastPathComponent() // ScreenMirror
            .deletingLastPathComponent() // Features
            .deletingLastPathComponent() // Connect
            .deletingLastPathComponent() // mac
            .deletingLastPathComponent() // repo root
        let jarURL = repoRoot.appendingPathComponent("android/screen-server/scrcpy-server.jar")
        return FileManager.default.fileExists(atPath: jarURL.path) ? jarURL : nil
    }

    /// Pushes the vendored server jar to `/data/local/tmp` unless a file of
    /// the same byte size is already there — a cheap "version marker" that
    /// avoids a ~700KB `adb push` on every mirror session while still
    /// re-pushing whenever the vendored jar changes (e.g. a scrcpy version
    /// bump). Not a cryptographic check, but `adb push`'s own size+mtime
    /// skip logic plus this pre-check is enough for a jar that only changes
    /// when a developer bumps `serverVersion`/re-vendors it.
    private func ensureScrcpyServerPushed() throws {
        guard let jarURL = ADBClient.vendoredServerJarURL() else {
            throw ADBError.serverJarMissing
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: jarURL.path)
        guard let localSize = attrs[.size] as? Int else {
            throw ADBError.serverJarMissing
        }

        if let remoteSizeData = try? run(["shell", "stat", "-c%s", Self.deviceServerPath]),
           let remoteSizeString = String(data: remoteSizeData, encoding: .utf8)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           let remoteSize = Int(remoteSizeString),
           remoteSize == localSize {
            return // already present and matching; skip the push
        }

        try run(["push", jarURL.path, Self.deviceServerPath])
    }

    /// Reserves a free local TCP port by binding to port 0 and reading back
    /// the OS-assigned port, then immediately releasing it for `adb forward`
    /// to bind. Small TOCTOU race (another process could grab it first) is
    /// an accepted risk for a local dev tool, same tier as the rest of this
    /// file's assumptions.
    private static func findAvailableLocalPort() -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return nil }

        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getResult = withUnsafeMutablePointer(to: &actual) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &len)
            }
        }
        guard getResult == 0 else { return nil }
        return UInt16(bigEndian: actual.sin_port)
    }

    /// Connects to the forwarded socket, retrying briefly.
    ///
    /// Two separate races are handled here, both discovered against the real
    /// device (see android/screen-server/README.md):
    ///  1. `adb shell` returns as soon as `app_process` starts, not once the
    ///     on-device server has actually bound its listening socket, so the
    ///     first few TCP-level connection attempts can fail outright.
    ///  2. More subtly, `adb forward`'s host-side TCP listener can complete a
    ///     handshake (`NWConnection` reaching `.ready`) *before* the
    ///     corresponding on-device `ServerSocket.accept()` has actually run —
    ///     adb accepts locally, then tears the connection down with a
    ///     zero-byte EOF once it discovers nothing is listening device-side
    ///     yet. A `.ready` state is therefore not sufficient; this only
    ///     treats a connection as usable once the *first real chunk of data*
    ///     has arrived, retrying a fresh connection attempt otherwise.
    private static func connectWithRetry(
        port: UInt16,
        attemptsRemaining: Int = 50,
        retryDelay: TimeInterval = 0.1,
        onData: @escaping (Data) -> Void,
        onFailure: @escaping (Error) -> Void,
        completion: @escaping (Result<NWConnection, Error>) -> Void
    ) {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)

        func retryOrFail(_ error: Error) {
            connection.stateUpdateHandler = nil
            connection.cancel()
            if attemptsRemaining > 0 {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + retryDelay) {
                    connectWithRetry(
                        port: port,
                        attemptsRemaining: attemptsRemaining - 1,
                        retryDelay: retryDelay,
                        onData: onData,
                        onFailure: onFailure,
                        completion: completion
                    )
                }
            } else {
                completion(.failure(error))
            }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        onData(data)
                        startReceiving(connection, onData: onData, onFailure: onFailure)
                        completion(.success(connection))
                    } else if let error {
                        retryOrFail(ADBError.socketConnectFailed(error.localizedDescription))
                    } else {
                        // Empty read with no error: either the premature-EOF
                        // race described above, or a spurious empty wake —
                        // either way, retry rather than risk hanging forever.
                        retryOrFail(ADBError.socketConnectFailed(
                            isComplete ? "device closed the forwarded connection before sending data" : "no data received"
                        ))
                    }
                }
            case .failed(let error), .waiting(let error):
                retryOrFail(error)
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }

    private static func startReceiving(
        _ connection: NWConnection,
        onData: @escaping (Data) -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                onData(data)
            }
            if let error {
                onFailure(error)
                return
            }
            if isComplete {
                onFailure(ADBError.socketConnectFailed("stream closed"))
                return
            }
            startReceiving(connection, onData: onData, onFailure: onFailure)
        }
    }

    /// Pushes (if needed) and launches the vendored scrcpy server, sets up
    /// the `adb forward`, and connects to the resulting raw H.264 stream.
    /// `onData` fires on an arbitrary Network.framework queue (not main), and
    /// `onTermination` fires once — from either the on-device process dying
    /// or the socket closing/erroring — whichever happens first.
    func startScrcpyCapture(
        maxSize: Int? = nil,
        bitRate: Int = 8_000_000,
        onData: @escaping (Data) -> Void,
        onTermination: @escaping (Int32) -> Void
    ) throws -> ScreenCaptureSession {
        try ensureScrcpyServerPushed()

        guard let port = ADBClient.findAvailableLocalPort() else {
            throw ADBError.portUnavailable
        }

        // Set up the forward *before* launching the server: `tunnel_forward=true`
        // (below) makes the on-device server listen on the local abstract
        // socket itself, and a plain host->device `adb forward` is scrcpy's
        // own documented way to reach it without needing `adb reverse`.
        try run(["forward", "tcp:\(port)", "localabstract:\(Self.deviceSocketName)"])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = [
            "shell",
            "CLASSPATH=\(Self.deviceServerPath)",
            "app_process", "/", "com.genymobile.scrcpy.Server", Self.serverVersion,
            "log_level=info",
            "audio=false",
            "control=false",
            // `cleanup=false`: scrcpy's own `cleanup=true` deletes whatever
            // jar it was launched from (`SERVER_PATH`, derived from our
            // `CLASSPATH`) on exit, which would defeat the size-based
            // "already pushed" skip in `ensureScrcpyServerPushed` — every
            // session would have to re-push. The device-side state
            // `cleanup=true` also restores (show-touches, stay-awake, power
            // mode) isn't touched by `raw_stream=true` capture anyway.
            "cleanup=false",
            "raw_stream=true",
            "tunnel_forward=true",
        ] + (maxSize.map { ["max_size=\($0)"] } ?? []) + ["video_bit_rate=\(bitRate)"]

        process.standardOutput = Pipe() // server's stdout is unused in raw_stream mode
        process.standardError = Pipe()  // discarded; server logs nothing actionable here in raw_stream mode

        var terminationFired = false
        let terminationLock = NSLock()
        let fireTermination: (Int32) -> Void = { code in
            terminationLock.lock()
            defer { terminationLock.unlock() }
            guard !terminationFired else { return }
            terminationFired = true
            onTermination(code)
        }

        process.terminationHandler = { proc in
            fireTermination(proc.terminationStatus)
        }
        try process.run()

        let semaphore = DispatchSemaphore(value: 0)
        var connectionResult: Result<NWConnection, Error>!
        ADBClient.connectWithRetry(
            port: port,
            onData: onData,
            onFailure: { _ in fireTermination(-1) },
            completion: { result in
                connectionResult = result
                semaphore.signal()
            }
        )
        semaphore.wait()

        switch connectionResult! {
        case .success(let connection):
            return ScreenCaptureSession(process: process, connection: connection, adbPath: adbPath, forwardPort: port)
        case .failure(let error):
            process.terminationHandler = nil
            process.terminate()
            _ = try? run(["forward", "--remove", "tcp:\(port)"])
            throw error
        }
    }
}
