import AppKit
import AVFoundation
import CoreMedia

/// AppKit window that renders the ADB-mirrored phone screen via
/// `AVSampleBufferDisplayLayer` and forwards mouse/keyboard input back to the
/// device as `adb shell input ...` commands through `ScreenMirrorController`.
///
/// **Not visually verified in this environment** — there was no way to
/// interactively confirm a rendered window on the build/test machine used for
/// this unit. The ADB capture pipeline that feeds it (`ADBClient` +
/// `H264Decoder`) was verified for real against the connected device; see the
/// unit's PR description for exactly what that means and what remains
/// unverified here.
final class ScreenMirrorWindow: NSWindow {
    private let controller: ScreenMirrorController
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let contentContainerView: NSView
    private var deviceAspect: CGFloat = 1080.0 / 2340.0
    private var eventMonitor: Any?
    private var dragStart: CGPoint?

    init(controller: ScreenMirrorController) {
        self.controller = controller
        let initialFrame = NSRect(x: 0, y: 0, width: 375, height: 812)
        contentContainerView = NSView(frame: initialFrame)

        super.init(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        title = "Phone Mirror"
        isReleasedWhenClosed = false
        contentView = contentContainerView

        contentContainerView.wantsLayer = true
        displayLayer.frame = contentContainerView.bounds
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        contentContainerView.layer?.addSublayer(displayLayer)

        controller.onFrame = { [weak self] pixelBuffer, pts in
            self?.enqueue(pixelBuffer: pixelBuffer, pts: pts)
        }
        controller.onDeviceSizeResolved = { [weak self] size in
            self?.updateDeviceSize(size)
        }

        installEventMonitor()
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    override func setContentSize(_ size: NSSize) {
        super.setContentSize(size)
        displayLayer.frame = contentContainerView.bounds
    }

    func updateDeviceSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        deviceAspect = size.width / size.height
        let height: CGFloat = 800
        setContentSize(NSSize(width: height * deviceAspect, height: height))
    }

    private func enqueue(pixelBuffer: CVPixelBuffer, pts: CMTime) {
        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard let formatDescription else { return }

        var timingInfo = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.displayLayer.status == .failed {
                self.displayLayer.flush()
            }
            self.displayLayer.enqueue(sampleBuffer)
        }
    }

    // MARK: - Input forwarding

    private func installEventMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
            guard let self, event.window === self else { return event }
            switch event.type {
            case .leftMouseDown:
                dragStart = locationInView(event)
            case .leftMouseUp:
                let end = locationInView(event)
                if let start = dragStart {
                    let dx = abs(end.x - start.x), dy = abs(end.y - start.y)
                    if dx < 4, dy < 4 {
                        controller.tap(pointInView: end, viewSize: contentContainerView.bounds.size)
                    } else {
                        controller.swipe(from: start, to: end, viewSize: contentContainerView.bounds.size)
                    }
                }
                dragStart = nil
            case .keyDown:
                forwardKeyEvent(event)
            default:
                break
            }
            return event
        }
    }

    private func locationInView(_ event: NSEvent) -> CGPoint {
        let pointInView = contentContainerView.convert(event.locationInWindow, from: nil)
        // AppKit's view origin is bottom-left; Android's `input tap`/`swipe` origin is top-left.
        return CGPoint(x: pointInView.x, y: contentContainerView.bounds.height - pointInView.y)
    }

    /// Best-effort key forwarding: printable characters go through `input
    /// text`, a handful of navigation/editing keys map to their Android
    /// `KEYCODE_*` equivalents. Not exhaustive (no modifier chords, no IME) —
    /// good enough for a v1 vertical slice.
    private func forwardKeyEvent(_ event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let characters = event.characters, !characters.isEmpty,
           characters.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == " " }) {
            controller.text(characters)
            return
        }

        switch event.keyCode {
        case 51: controller.keyevent(67) // Backspace -> KEYCODE_DEL
        case 36: controller.keyevent(66) // Return -> KEYCODE_ENTER
        case 53: controller.keyevent(4)  // Escape -> KEYCODE_BACK
        case 123: controller.keyevent(21) // Left arrow -> KEYCODE_DPAD_LEFT
        case 124: controller.keyevent(22) // Right arrow -> KEYCODE_DPAD_RIGHT
        case 125: controller.keyevent(20) // Down arrow -> KEYCODE_DPAD_DOWN
        case 126: controller.keyevent(19) // Up arrow -> KEYCODE_DPAD_UP
        default: break
        }
    }
}
