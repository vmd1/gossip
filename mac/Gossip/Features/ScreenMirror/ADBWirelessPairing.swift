import Foundation
import AppKit
import Combine

/// Drives Android's "Pair device with QR code" wireless-debugging flow
/// entirely through the `adb` CLI. No cryptography or wire protocol is
/// implemented here — the SPAKE2 pairing-code exchange and the subsequent TLS
/// handshake are both implemented inside the `adb` binary itself; this class
/// only generates the QR payload, shows it, polls `adb mdns services` for the
/// phone to show up, and shells out to `adb pair`/`adb connect`.
///
/// Technique credit: this is a Swift port of the control flow in `adbqr`
/// (https://github.com/kristjan/adbqr, MIT licensed) by kristjan — see its
/// `main()` for the reference bash implementation this follows: generate a
/// random service name + 6-digit pairing code, build the
/// `WIFI:T:ADB;S:<name>;P:<code>;;` QR payload (the `WIFI:` prefix is
/// Android's Wi-Fi QR format repurposed by the Wireless-debugging QR
/// scanner — `S:` is an mDNS service *name*, not an SSID, and `P:` is the
/// pairing *code*, not a password), then poll `adb mdns services` once a
/// second for a matching `_adb-tls-pairing._tcp` line and run `adb pair`.
/// This class additionally polls for `_adb-tls-connect._tcp` afterward and
/// runs `adb connect`, since `adbqr` stops after pairing and leaves the
/// actual ADB-over-Wi-Fi connection to the caller.
final class ADBWirelessPairing: ObservableObject {
    enum State: Equatable {
        case idle
        /// Also covers polling for the phone to scan it — the QR must stay on screen for
        /// the whole wait, not just while it's first shown. A previous version of this flow
        /// moved to a separate `.waitingForPairing` state (with no QR) the instant polling
        /// started, which in practice meant the QR was replaced by a bare "waiting" spinner
        /// before the user had any real chance to scan it — confirmed live, not theoretical.
        case showingQR(payload: String, qrImage: NSImage)
        case pairing
        case waitingForConnect
        case connecting
        /// `verifiedAgainstPairedDevice` is true when a Connect-trusted phone
        /// was already connected and its IP matched the one this ADB flow
        /// discovered over mDNS (see `verifyMatchesTrustedPeer`); false means
        /// either there was nothing to cross-check against, or it didn't
        /// match (in which case the flow fails instead of reaching here).
        case connected(serial: String, verifiedAgainstPairedDevice: Bool)
        case failed(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle),
                 (.pairing, .pairing), (.waitingForConnect, .waitingForConnect),
                 (.connecting, .connecting):
                return true
            case let (.showingQR(p1, _), .showingQR(p2, _)):
                return p1 == p2
            case let (.connected(s1, v1), .connected(s2, v2)):
                return s1 == s2 && v1 == v2
            case let (.failed(m1), .failed(m2)):
                return m1 == m2
            default:
                return false
            }
        }
    }

    /// How long to poll for each mDNS service before giving up.
    static let mdnsTimeoutSeconds = 60
    private static let pollIntervalNanos: UInt64 = 1_000_000_000

    @Published private(set) var state: State = .idle

    private let adbPath: String
    /// The IP (no port) of the phone already trust-paired over the
    /// Noise-encrypted Connect transport, if any. Supplied by the caller
    /// (`MenuBarView`/`ScreenMirrorController`) from `TransportManager`.
    /// Used only for the defense-in-depth check in step 4 of this unit.
    var trustedPeerIP: String?

    private var task: Task<Void, Never>?

    init(adbPath: String) {
        self.adbPath = adbPath
    }

    func start() {
        cancel()

        let serviceName = "connect-\(Self.randomServiceSuffix())"
        let pairingCode = Self.randomPairingCode()
        let payload = Self.qrPayload(serviceName: serviceName, pairingCode: pairingCode)

        guard let qrImage = QRCodeGenerator.image(forData: Data(payload.utf8)) else {
            state = .failed("Failed to render QR code")
            return
        }
        state = .showingQR(payload: payload, qrImage: qrImage)

        task = Task { [weak self] in
            await self?.runFlow(serviceName: serviceName, pairingCode: pairingCode)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }

    // MARK: - Flow

    private func runFlow(serviceName: String, pairingCode: String) async {
        // State is already `.showingQR` (set by `start()`) and deliberately stays that way
        // through this whole poll — see the case's doc for why.
        guard let pairingAddress = await pollMDNS(serviceType: "_adb-tls-pairing._tcp") else {
            await setState(.failed("Timed out waiting for the phone to scan the QR code"))
            return
        }
        if Task.isCancelled { return }

        await setState(.pairing)
        do {
            try await runADB(["pair", pairingAddress, pairingCode])
        } catch {
            await setState(.failed("adb pair failed: \(error.localizedDescription)"))
            return
        }
        if Task.isCancelled { return }

        await setState(.waitingForConnect)
        guard let connectAddress = await pollMDNS(serviceType: "_adb-tls-connect._tcp") else {
            await setState(.failed("Paired, but timed out waiting for the ADB-over-Wi-Fi service to appear. Try toggling Wireless debugging off and on."))
            return
        }
        if Task.isCancelled { return }

        await setState(.connecting)
        do {
            try await runADB(["connect", connectAddress])
        } catch {
            await setState(.failed("adb connect failed: \(error.localizedDescription)"))
            return
        }
        if Task.isCancelled { return }

        guard let serial = await resolveConnectedSerial(matching: connectAddress) else {
            await setState(.failed("adb connect succeeded but the device isn't listed as authorized. Check for an 'Allow' prompt on the phone."))
            return
        }

        let verified = Self.verifyMatchesTrustedPeer(discoveredAddress: connectAddress, trustedPeerIP: trustedPeerIP)
        await setState(.connected(serial: serial, verifiedAgainstPairedDevice: verified))
    }

    /// Polls `adb mdns services` once a second, up to `mdnsTimeoutSeconds`,
    /// for a line matching `serviceType`. Mirrors `adbqr`'s poll loop.
    private func pollMDNS(serviceType: String) async -> String? {
        for _ in 0..<Self.mdnsTimeoutSeconds {
            if Task.isCancelled { return nil }
            if let output = try? await runADBCapturingOutput(["mdns", "services"]),
               let address = Self.parseMDNSAddress(output, serviceType: serviceType) {
                return address
            }
            try? await Task.sleep(nanoseconds: Self.pollIntervalNanos)
        }
        return nil
    }

    /// After `adb connect`, resolve the serial adb assigned this device
    /// (normally identical to `connectAddress`) and confirm its state is
    /// `device` (fully authorized), not `unauthorized`/`offline`.
    private func resolveConnectedSerial(matching connectAddress: String) async -> String? {
        guard let output = try? await runADBCapturingOutput(["devices", "-l"]) else { return nil }
        return Self.parseAuthorizedSerial(output, matching: connectAddress)
    }

    @MainActor
    private func setState(_ newState: State) {
        state = newState
    }

    // MARK: - Process execution

    private func runADB(_ args: [String]) async throws {
        _ = try await runADBCapturingOutput(args)
    }

    private func runADBCapturingOutput(_ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: adbPath)
            process.arguments = args
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.terminationHandler = { proc in
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outData, encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                    let errString = String(data: errData, encoding: .utf8) ?? "unknown error"
                    continuation.resume(throwing: ADBError.processFailed(errString.isEmpty ? output : errString))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Pure helpers (unit tested independently of any `adb`/device)

    static func randomServiceSuffix(length: Int = 8) -> String {
        let chars = Array("0123456789abcdef")
        return String((0..<length).compactMap { _ in chars.randomElement() })
    }

    static func randomPairingCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    /// Builds the `WIFI:T:ADB;S:<name>;P:<code>;;` QR payload Android's
    /// Wireless debugging QR scanner expects.
    static func qrPayload(serviceName: String, pairingCode: String) -> String {
        "WIFI:T:ADB;S:\(serviceName);P:\(pairingCode);;"
    }

    /// Parses `adb mdns services` output for the address of the first line
    /// whose service type matches `serviceType`. Output lines look like:
    ///   `adb-XXXXXXXX-XXXXXX._adb-tls-pairing._tcp.  192.168.1.23:41234`
    /// or (tab-separated, older adb): `<name>\t<type>\t<addr:port>`. Either
    /// way this takes the 3rd whitespace-separated field, matching adbqr's
    /// `awk '/_adb-tls-pairing\._tcp/ {print $3; exit}'`.
    static func parseMDNSAddress(_ output: String, serviceType: String) -> String? {
        for rawLine in output.split(separator: "\n") {
            guard rawLine.contains(serviceType) else { continue }
            let fields = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 3 else { continue }
            return String(fields[2])
        }
        return nil
    }

    /// Parses `adb devices -l` output for the serial matching
    /// `connectAddress` (adb serials for TCP/IP devices are the `ip:port`
    /// string itself), returning it only if its state is `device` (fully
    /// authorized) rather than `unauthorized`/`offline`.
    static func parseAuthorizedSerial(_ output: String, matching connectAddress: String) -> String? {
        for rawLine in output.split(separator: "\n").dropFirst() {
            let fields = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let serial = fields.first.map(String.init), serial == connectAddress else { continue }
            guard fields.count >= 2, fields[1] == "device" else { return nil }
            return serial
        }
        return nil
    }

    /// Parses `adb devices -l` for the first serial in the fully-authorized
    /// `device` state (skips `unauthorized`/`offline`). Used by
    /// `MenuBarView` to check for an already-connected device (typically
    /// USB) before falling back to the QR pairing flow.
    static func firstAuthorizedSerial(_ output: String) -> String? {
        for rawLine in output.split(separator: "\n").dropFirst() {
            let fields = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, fields[1] == "device" else { continue }
            return String(fields[0])
        }
        return nil
    }

    /// Parses `adb devices -l` for the first authorized (`device`-state) serial whose
    /// address matches `ip` — the IP portion of a wireless `ip:port` adb serial. Used
    /// to resolve which physical `adb`-visible device corresponds to a *specific*
    /// mesh-trusted device, now that more than one Android device can be trusted (and
    /// visible to `adb`) at once — unlike `firstAuthorizedSerial(_:)` above, which just
    /// grabs whichever device `adb` happens to list first.
    static func firstAuthorizedSerial(_ output: String, matchingIP ip: String) -> String? {
        for rawLine in output.split(separator: "\n").dropFirst() {
            let fields = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let serial = fields.first.map(String.init) else { continue }
            guard fields.count >= 2, fields[1] == "device" else { continue }
            let serialIP = serial.split(separator: ":").first.map(String.init) ?? serial
            if serialIP == ip { return serial }
        }
        return nil
    }

    /// Defense-in-depth device-identity check (see this unit's PR
    /// description): compares the IP the ADB pairing/connect flow discovered
    /// over mDNS against the IP of the phone already trust-paired over the
    /// Noise-encrypted Connect transport, when there is one. Returns `false`
    /// (not "unverified"/nil) whenever there's nothing to compare against —
    /// callers distinguish "no Gossip pairing to check" from "verified" via
    /// `trustedPeerIP == nil`, and show different UI copy for each case.
    static func verifyMatchesTrustedPeer(discoveredAddress: String, trustedPeerIP: String?) -> Bool {
        guard let trustedPeerIP, !trustedPeerIP.isEmpty else { return false }
        let discoveredIP = discoveredAddress.split(separator: ":").first.map(String.init) ?? discoveredAddress
        return discoveredIP == trustedPeerIP
    }
}
