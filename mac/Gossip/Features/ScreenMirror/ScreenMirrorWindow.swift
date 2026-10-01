import AppKit
import AVFoundation
import CoreMedia

/// Turns the bridge's H.264 packets into frames on an `AVSampleBufferDisplayLayer` (which
/// hardware-decodes through VideoToolbox itself, so there's no separate decode session to
/// manage). Annex-B → AVCC conversion and SPS/PPS handling live in `H264`.
/// Not thread-safe: call from one queue (`ScreenBridgeClient`'s).
final class H264SampleFeeder {
    private let layer: AVSampleBufferDisplayLayer
    private var formatDescription: CMVideoFormatDescription?
    private var lastParameterSets: (sps: Data, pps: Data)?
    private var waitingForKeyFrame = true
    private(set) var framesEnqueued = 0

    /// Called when the layer failed and we need the phone to send a fresh key frame.
    var onNeedsKeyFrame: (() -> Void)?

    init(layer: AVSampleBufferDisplayLayer) {
        self.layer = layer
    }

    func handle(flags: UInt64, payload: Data) {
        if flags & BridgeMessage.configFlag != 0 {
            configure(withConfig: payload)
            return
        }
        guard let formatDescription else { return }
        let isKey = flags & BridgeMessage.keyFrameFlag != 0
        if layer.status == .failed {
            layer.flush()
            waitingForKeyFrame = true
            onNeedsKeyFrame?()
        }
        if waitingForKeyFrame && !isKey { return } // can't start decoding mid-GOP
        if isKey { waitingForKeyFrame = false }

        let avcc = H264.avcc(fromAnnexB: payload)
        guard !avcc.isEmpty, let sample = Self.makeSampleBuffer(avcc: avcc, format: formatDescription) else { return }
        layer.enqueue(sample)
        framesEnqueued += 1
    }

    private func configure(withConfig config: Data) {
        guard let sets = H264.parameterSets(fromConfig: config) else { return }
        if let last = lastParameterSets, last.sps == sets.sps, last.pps == sets.pps { return } // replay after RESET_VIDEO
        var newDescription: CMVideoFormatDescription?
        let status = sets.sps.withUnsafeBytes { spsPtr in
            sets.pps.withUnsafeBytes { ppsPtr in
                let pointers = [spsPtr.bindMemory(to: UInt8.self).baseAddress!, ppsPtr.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sets.sps.count, sets.pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &newDescription
                )
            }
        }
        guard status == noErr, let newDescription else {
            NSLog("Gossip: could not build H.264 format description (OSStatus \(status))")
            return
        }
        formatDescription = newDescription
        lastParameterSets = sets
        waitingForKeyFrame = true // new SPS/PPS: wait for the key frame that follows
    }

    private static func makeSampleBuffer(avcc: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: avcc.count, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block
        ) == noErr, let block else { return nil }
        let copied = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copied == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var size = avcc.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }

        // Live stream: show each frame as soon as it's decoded, no presentation scheduling.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sample
    }
}

/// The view inside the mirror window: hosts the video layer and maps mouse / scroll / keyboard
/// to scrcpy control messages in the phone's coordinate space.
final class MirrorContentView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()
    /// Current encoded size; touch positions are reported against this.
    var videoSize = CGSize(width: 1, height: 1)
    var sendControl: ((Data) -> Void)?
    /// Sends already-encoded control bytes for context-menu / shortcut actions.
    var menuActions: ((Data) -> Void)?
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?
    private var dragging = false
    /// Height of the strip at the top that moves the window instead of touching the phone.
    private static let dragStripHeight: CGFloat = 26
    private var lastPoint: (x: Int, y: Int, w: Int, h: Int)?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { true } // y grows downward, like the phone

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer = displayLayer
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func devicePoint(_ event: NSEvent) -> (x: Int, y: Int, w: Int, h: Int)? {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        // The window's content aspect ratio is locked to the video, but be safe about letterboxing.
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let drawn = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        let origin = CGPoint(x: (bounds.width - drawn.width) / 2, y: (bounds.height - drawn.height) / 2)
        let nx = (p.x - origin.x) / drawn.width, ny = (p.y - origin.y) / drawn.height
        guard nx >= 0, nx <= 1, ny >= 0, ny <= 1 else { return nil }
        let w = Int(videoSize.width), h = Int(videoSize.height)
        return (min(w - 1, Int(nx * videoSize.width)), min(h - 1, Int(ny * videoSize.height)), w, h)
    }

    private func touch(_ action: ScrcpyControl.TouchAction, _ event: NSEvent) {
        guard let p = devicePoint(event) else {
            if action == .up, let last = lastPoint { // released outside the video: lift at the last point
                sendControl?(ScrcpyControl.touch(.up, x: last.x, y: last.y, width: last.w, height: last.h))
            }
            return
        }
        lastPoint = p
        sendControl?(ScrcpyControl.touch(action, x: p.x, y: p.y, width: p.w, height: p.h))
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if convert(event.locationInWindow, from: nil).y < Self.dragStripHeight {
            dragging = true // the thin top strip drags the window, like the native mirroring window
            window?.performDrag(with: event)
            return
        }
        dragging = false
        touch(.down, event)
    }
    override func mouseDragged(with event: NSEvent) { if !dragging { touch(.move, event) } }
    override func mouseUp(with event: NSEvent) { if !dragging { touch(.up, event) }; dragging = false }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (title, key, data) in Self.actions {
            let item = NSMenuItem(title: title, action: #selector(runMenuAction(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = .command
            item.target = self
            item.representedObject = data
            menu.addItem(item)
        }
        return menu
    }

    @objc private func runMenuAction(_ item: NSMenuItem) {
        if let data = item.representedObject as? Data { menuActions?(data) }
    }

    private static let actions: [(String, String, Data)] = [
        ("Home", "1", ScrcpyControl.keyPress(ScrcpyControl.Key.home)),
        ("App Switcher", "2", ScrcpyControl.keyPress(ScrcpyControl.Key.appSwitch)),
        ("Notifications", "3", ScrcpyControl.expandNotifications),
        ("Back", "[", ScrcpyControl.keyPress(ScrcpyControl.Key.back)),
    ]

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers,
              let action = Self.actions.first(where: { $0.1 == key }) else { return super.performKeyEquivalent(with: event) }
        menuActions?(action.2)
        return true
    }

    override func scrollWheel(with event: NSEvent) {
        guard let p = devicePoint(event) else { return }
        // Trackpads report points; one wheel notch ≈ 10 points feels right at the phone's density.
        let divisor: Double = event.hasPreciseScrollingDeltas ? 10 : 1
        sendControl?(ScrcpyControl.scroll(
            x: p.x, y: p.y, width: p.w, height: p.h,
            horizontal: Double(event.scrollingDeltaX) / divisor, vertical: Double(event.scrollingDeltaY) / divisor
        ))
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { return super.keyDown(with: event) }
        let special: [UInt16: UInt32] = [
            36: ScrcpyControl.Key.enter, 76: ScrcpyControl.Key.enter, 51: ScrcpyControl.Key.delete,
            117: ScrcpyControl.Key.forwardDelete, 48: ScrcpyControl.Key.tab, 53: ScrcpyControl.Key.back,
            123: ScrcpyControl.Key.dpadLeft, 124: ScrcpyControl.Key.dpadRight,
            125: ScrcpyControl.Key.dpadDown, 126: ScrcpyControl.Key.dpadUp,
        ]
        if let code = special[event.keyCode] {
            sendControl?(ScrcpyControl.keyPress(code))
        } else if let chars = event.characters, let text = ScrcpyControl.text(chars),
                  !chars.unicodeScalars.contains(where: { $0.value < 0x20 || (0xF700...0xF8FF).contains($0.value) }) {
            sendControl?(text)
        }
    }
}

/// Window showing one device's mirrored screen, styled like the native iPhone Mirroring window:
/// no visible title bar or toolbar, content runs edge to edge, the traffic lights appear only
/// while the pointer is over the window, and the window is dragged by a thin strip at the top.
/// Back / Home / Recents / Notifications live on right-click and ⌘1 / ⌘2 / ⌘[ / ⌘3.
/// Closing it ends the session (`onClose`).
final class ScreenMirrorWindow: NSWindow, NSWindowDelegate {
    let content = MirrorContentView(frame: .zero)
    var onClose: (() -> Void)?
    var sendControl: ((Data) -> Void)? {
        didSet { content.sendControl = sendControl }
    }

    init(deviceName: String, videoSize: CGSize) {
        let initial = Self.fittedSize(for: videoSize)
        super.init(
            contentRect: NSRect(origin: .zero, size: initial),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        title = deviceName.isEmpty ? "Mirroring" : deviceName // still used by Mission Control / Dock
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .black
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false // content handles touches; the top strip drags (see MirrorContentView)
        delegate = self
        contentView = content
        content.videoSize = videoSize
        content.menuActions = { [weak self] in self?.sendControl?($0) }
        content.onHover = { [weak self] inside in self?.setTrafficLights(visible: inside) }
        contentAspectRatio = videoSize
        setTrafficLights(visible: false)
        center()
    }

    private func setTrafficLights(visible: Bool) {
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(kind)?.animator().alphaValue = visible ? 1 : 0
        }
    }

    /// Called on the main thread when the phone reports a new encoded size (e.g. rotation).
    func updateVideoSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != content.videoSize else { return }
        content.videoSize = size
        contentAspectRatio = size
        setContentSize(Self.fittedSize(for: size))
    }

    /// Roughly 80% of the screen height, preserving the video's aspect ratio.
    private static func fittedSize(for video: CGSize) -> CGSize {
        let maxH = (NSScreen.main?.visibleFrame.height ?? 900) * 0.8
        let maxW = (NSScreen.main?.visibleFrame.width ?? 1400) * 0.8
        let scale = min(maxH / video.height, maxW / video.width, 1)
        return CGSize(width: (video.width * scale).rounded(), height: (video.height * scale).rounded())
    }

    func windowWillClose(_ notification: Notification) {
        let handler = onClose
        onClose = nil
        handler?()
    }
}
