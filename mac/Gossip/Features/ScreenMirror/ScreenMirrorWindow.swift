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

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); touch(.down, event) }
    override func mouseDragged(with event: NSEvent) { touch(.move, event) }
    override func mouseUp(with event: NSEvent) { touch(.up, event) }

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

/// Window showing one device's mirrored screen. Closing it ends the session (`onClose`).
final class ScreenMirrorWindow: NSWindow, NSWindowDelegate, NSToolbarDelegate {
    let content = MirrorContentView(frame: .zero)
    var onClose: (() -> Void)?
    var sendControl: ((Data) -> Void)? {
        didSet { content.sendControl = sendControl }
    }

    private static let itemBack = NSToolbarItem.Identifier("gossip.back")
    private static let itemHome = NSToolbarItem.Identifier("gossip.home")
    private static let itemRecents = NSToolbarItem.Identifier("gossip.recents")

    init(deviceName: String, videoSize: CGSize) {
        let initial = Self.fittedSize(for: videoSize)
        super.init(
            contentRect: NSRect(origin: .zero, size: initial),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        title = deviceName.isEmpty ? "Mirroring" : "\(deviceName) — Mirroring"
        isReleasedWhenClosed = false
        delegate = self
        contentView = content
        content.videoSize = videoSize
        contentAspectRatio = videoSize
        let toolbar = NSToolbar(identifier: "gossip.mirror")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        self.toolbar = toolbar
        center()
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

    // MARK: Toolbar (Back / Home / Recents)

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.itemBack, Self.itemHome, Self.itemRecents, .flexibleSpace]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.itemBack, Self.itemHome, Self.itemRecents]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let spec: [NSToolbarItem.Identifier: (String, String, Selector)] = [
            Self.itemBack: ("chevron.backward", "Back", #selector(pressBack)),
            Self.itemHome: ("circle", "Home", #selector(pressHome)),
            Self.itemRecents: ("square.on.square", "Recents", #selector(pressRecents)),
        ]
        guard let (symbol, label, action) = spec[id] else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = self
        item.action = action
        return item
    }

    @objc private func pressBack() { sendControl?(ScrcpyControl.keyPress(ScrcpyControl.Key.back)) }
    @objc private func pressHome() { sendControl?(ScrcpyControl.keyPress(ScrcpyControl.Key.home)) }
    @objc private func pressRecents() { sendControl?(ScrcpyControl.keyPress(ScrcpyControl.Key.appSwitch)) }
}
