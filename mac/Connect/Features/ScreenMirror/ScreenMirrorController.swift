import Foundation
import CoreMedia
import Combine

/// Orchestrates the ADB-mediated screen mirroring pipeline end to end:
/// resolves `adb` + the connected device's screen size, starts an `adb
/// exec-out screenrecord` H.264 capture (`ADBClient`), feeds the raw bytes
/// into `H264Decoder`, hands decoded frames to whatever's listening
/// (`ScreenMirrorWindow` via `onFrame`), and turns window input (taps/drags/
/// keys) back into `adb shell input ...` commands.
///
/// Deliberately independent of `TransportManager`/`MessageRouter`: mirroring
/// itself is not a Noise-encrypted, JSON-enveloped feature — it runs over a
/// local ADB tunnel that's already trusted by virtue of the on-device "Allow
/// USB debugging?" RSA key approval. `TransportManager` is only used
/// separately (see `MenuBarView`) to send the `screen.start`/`screen.stop`
/// signaling messages so the Android app's UI can reflect mirroring state —
/// this controller works whether or not a Noise session is currently
/// connected, as long as `adb devices` shows the phone. See the unit's PR
/// description for the full rationale and what was verified against real
/// hardware vs. not.
final class ScreenMirrorController: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case mirroring(deviceSize: CGSize)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let decoder = H264Decoder()
    private var adb: ADBClient?
    private var captureProcess: Process?
    private var deviceSize: (width: Int, height: Int)?

    /// Called with every decoded frame, on an arbitrary (non-main) queue.
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)? {
        get { decoder.onDecodedFrame }
        set { decoder.onDecodedFrame = newValue }
    }

    /// Called on device-size resolution, on the main queue.
    var onDeviceSizeResolved: ((CGSize) -> Void)?

    init() {
        decoder.onError = { error in
            NSLog("Connect: H264 decode error: \(error.localizedDescription)")
        }
    }

    /// - Parameter serial: When known (e.g. resolved by `ADBWirelessPairing`
    ///   or an existing `adb devices -l` check in `MenuBarView`), every `adb`
    ///   command is targeted at this exact device via `-s <serial>` instead
    ///   of relying on `adb`'s single-device auto-detection.
    func start(serial: String? = nil) {
        guard case .idle = state else { return }
        state = .starting

        guard let adb = ADBClient(serial: serial) else {
            setState(.failed("adb not found on PATH"))
            return
        }
        self.adb = adb

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                guard try adb.hasConnectedDevice() else {
                    self.setState(.failed("No Android device connected via adb"))
                    return
                }
                let size = try adb.screenSize()
                self.deviceSize = size
                DispatchQueue.main.async {
                    self.onDeviceSizeResolved?(CGSize(width: size.width, height: size.height))
                }

                try self.launchCaptureProcess(adb: adb)
                self.setState(.mirroring(deviceSize: CGSize(width: size.width, height: size.height)))
            } catch {
                self.setState(.failed(error.localizedDescription))
            }
        }
    }

    private func launchCaptureProcess(adb: ADBClient) throws {
        let process = try adb.startH264Capture(
            onData: { [weak self] data in
                self?.decoder.push(data)
            },
            onTermination: { [weak self] _ in
                guard let self else { return }
                // `screenrecord` can terminate on its own (encoder hiccup, USB blip);
                // transparently restart while the user still wants to be mirroring.
                if case .mirroring = self.state {
                    self.restartCapture()
                }
            }
        )
        captureProcess = process
    }

    private func restartCapture() {
        guard let adb else { return }
        do {
            try launchCaptureProcess(adb: adb)
        } catch {
            setState(.failed(error.localizedDescription))
        }
    }

    func stop() {
        captureProcess?.terminationHandler = nil
        captureProcess?.terminate()
        captureProcess = nil
        decoder.reset()
        adb = nil
        deviceSize = nil
        state = .idle
    }

    // MARK: - Input forwarding

    /// Translates a point in the mirrored view's own bounds (origin
    /// top-left, `viewSize` in points) into a device tap, scaling into
    /// device pixels using the last-resolved `wm size`.
    func tap(pointInView: CGPoint, viewSize: CGSize) {
        guard let adb, let size = deviceSize else { return }
        let (dx, dy) = deviceCoordinates(pointInView, viewSize: viewSize, deviceSize: size)
        adb.tap(x: dx, y: dy)
    }

    func swipe(from: CGPoint, to: CGPoint, viewSize: CGSize, durationMs: Int = 150) {
        guard let adb, let size = deviceSize else { return }
        let (x1, y1) = deviceCoordinates(from, viewSize: viewSize, deviceSize: size)
        let (x2, y2) = deviceCoordinates(to, viewSize: viewSize, deviceSize: size)
        adb.swipe(x1: x1, y1: y1, x2: x2, y2: y2, durationMs: durationMs)
    }

    func keyevent(_ code: Int) {
        adb?.keyevent(code)
    }

    func text(_ string: String) {
        adb?.text(string)
    }

    private func deviceCoordinates(_ point: CGPoint, viewSize: CGSize, deviceSize: (width: Int, height: Int)) -> (Int, Int) {
        guard viewSize.width > 0, viewSize.height > 0 else { return (0, 0) }
        let scaleX = CGFloat(deviceSize.width) / viewSize.width
        let scaleY = CGFloat(deviceSize.height) / viewSize.height
        let x = min(max(Int(point.x * scaleX), 0), deviceSize.width)
        let y = min(max(Int(point.y * scaleY), 0), deviceSize.height)
        return (x, y)
    }

    private func setState(_ newState: State) {
        DispatchQueue.main.async { [weak self] in
            self?.state = newState
        }
    }
}
