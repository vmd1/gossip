import Foundation

/// Pure (no UI, no networking) pieces of the on-device screen-mirroring viewer: parsing the
/// Android bridge's WebSocket messages, encoding scrcpy control messages, and the Annex-B →
/// AVCC conversion H.264 needs before VideoToolbox/AVSampleBufferDisplayLayer will take it.
/// The bridge's wire format is documented in `android/.../ScreenBridge.kt` and
/// `android/screen-server/README.md`; the scrcpy layouts below were verified against the
/// bundled scrcpy 4.1 server (touch opened an app, scroll moved a list, BACK navigated back).

/// One binary WebSocket message from the phone's bridge.
enum BridgeMessage: Equatable {
    /// `0x00`: `u64 BE pts/flags` then Annex-B H.264. Flag bit 62 = config (SPS+PPS), bit 61 = key frame.
    case video(flags: UInt64, payload: Data)
    /// `0x01`: encoded frame size changed (rotation / `RESET_VIDEO`).
    case size(width: Int, height: Int)
    /// `0x02`: raw scrcpy device-message bytes (clipboard etc.). Currently ignored by the viewer.
    case deviceMessage(Data)
    /// `0x03`: `u64 BE pts/flags` then interleaved signed-16-bit little-endian PCM (only when the header announced audio).
    case audio(Data)

    static let configFlag: UInt64 = 1 << 62
    static let keyFrameFlag: UInt64 = 1 << 61

    static func parse(_ data: Data) -> BridgeMessage? {
        guard let kind = data.first else { return nil }
        let body = data.dropFirst()
        switch kind {
        case 0x00:
            guard body.count >= 8 else { return nil }
            return .video(flags: body.prefix(8).bigEndianUInt64(), payload: Data(body.dropFirst(8)))
        case 0x01:
            guard body.count == 8 else { return nil }
            let w = Int(body.prefix(4).bigEndianUInt32()), h = Int(body.suffix(4).bigEndianUInt32())
            return .size(width: w, height: h)
        case 0x02:
            return .deviceMessage(Data(body))
        case 0x03:
            guard body.count > 8 else { return nil }
            return .audio(Data(body.dropFirst(8)))
        default:
            return nil
        }
    }
}

/// The text header the bridge sends right after the token is accepted.
struct BridgeStreamHeader: Equatable {
    struct Audio: Equatable { let sampleRate: Int; let channels: Int }
    let codec: String
    let width: Int
    let height: Int
    let deviceName: String
    /// Present only when the phone is capturing audio (`raw` s16le PCM).
    var audio: Audio? = nil

    static func parse(_ text: Data) -> BridgeStreamHeader? {
        guard let obj = (try? JSONSerialization.jsonObject(with: text)) as? [String: Any],
              let codec = obj["codec"] as? String,
              let width = obj["width"] as? Int, let height = obj["height"] as? Int else { return nil }
        var audio: Audio?
        if let a = obj["audio"] as? [String: Any], a["codec"] as? String == "raw", a["format"] as? String == "s16le",
           let rate = a["sampleRate"] as? Int, let ch = a["channels"] as? Int, rate > 0, (1...2).contains(ch) {
            audio = Audio(sampleRate: rate, channels: ch)
        }
        return BridgeStreamHeader(codec: codec, width: width, height: height, deviceName: obj["deviceName"] as? String ?? "", audio: audio)
    }
}

/// Encoders for the scrcpy 4.1 control messages the viewer sends back (client → server).
enum ScrcpyControl {
    enum TouchAction: UInt8 { case down = 0, up = 1, move = 2 }

    /// Android `KeyEvent` codes the viewer maps to.
    enum Key {
        static let home: UInt32 = 3, back: UInt32 = 4, tab: UInt32 = 61, enter: UInt32 = 66
        static let delete: UInt32 = 67, forwardDelete: UInt32 = 112, appSwitch: UInt32 = 187
        static let dpadUp: UInt32 = 19, dpadDown: UInt32 = 20, dpadLeft: UInt32 = 21, dpadRight: UInt32 = 22
    }

    /// `INJECT_TOUCH_EVENT` (type 2): action, pointerId u64, position (x,y u32 + screen w,h u16),
    /// pressure u16 fixed-point, actionButton u32, buttons u32. Pointer id 0 = a finger.
    static func touch(_ action: TouchAction, x: Int, y: Int, width: Int, height: Int) -> Data {
        var d = Data([2, action.rawValue])
        d.appendBE(UInt64(0))
        d.appendBE(UInt32(clamping: x)); d.appendBE(UInt32(clamping: y))
        d.appendBE(UInt16(clamping: width)); d.appendBE(UInt16(clamping: height))
        d.appendBE(action == .up ? UInt16(0) : UInt16(0xffff))
        d.appendBE(UInt32(0)); d.appendBE(UInt32(0))
        return d
    }

    /// `INJECT_SCROLL_EVENT` (type 3): position, then h/v scroll as i16 fixed-point (±16 "wheel
    /// notches" ↔ ±0x7fff), buttons u32. Positive vertical = wheel up (content moves down).
    static func scroll(x: Int, y: Int, width: Int, height: Int, horizontal: Double, vertical: Double) -> Data {
        func fixed(_ v: Double) -> Int16 { Int16((max(-16, min(16, v)) / 16 * 32767).rounded()) }
        var d = Data([3])
        d.appendBE(UInt32(clamping: x)); d.appendBE(UInt32(clamping: y))
        d.appendBE(UInt16(clamping: width)); d.appendBE(UInt16(clamping: height))
        d.appendBE(fixed(horizontal)); d.appendBE(fixed(vertical))
        d.appendBE(UInt32(0))
        return d
    }

    /// `INJECT_KEYCODE` (type 0): action (0 down / 1 up), keycode, repeat, metastate.
    static func keycode(_ code: UInt32, down: Bool) -> Data {
        var d = Data([0, down ? 0 : 1])
        d.appendBE(code); d.appendBE(UInt32(0)); d.appendBE(UInt32(0))
        return d
    }

    /// Down + up as one write (two messages back to back).
    static func keyPress(_ code: UInt32) -> Data { keycode(code, down: true) + keycode(code, down: false) }

    /// `INJECT_TEXT` (type 1): u32 length + UTF-8 (server limit 300 bytes; longer input is truncated).
    static func text(_ s: String) -> Data? {
        var bytes = Array(s.utf8)
        guard !bytes.isEmpty else { return nil }
        if bytes.count > 300 {
            bytes = Array(String(decoding: bytes.prefix(300), as: UTF8.self).utf8) // never split a code point
        }
        var d = Data([1]); d.appendBE(UInt32(bytes.count)); d.append(contentsOf: bytes)
        return d
    }

    /// `EXPAND_NOTIFICATION_PANEL` (type 5).
    static let expandNotifications = Data([5])

    /// `RESET_VIDEO` (type 17): server re-emits size + config + a key frame.
    static let resetVideo = Data([17])
}

/// H.264 Annex-B helpers.
enum H264 {
    /// Splits an Annex-B buffer on 3- or 4-byte start codes into bare NAL units.
    static func splitAnnexB(_ data: Data) -> [Data] {
        let b = [UInt8](data)
        var starts: [(codeStart: Int, nalStart: Int)] = []
        var i = 0
        while i + 2 < b.count {
            if b[i] == 0, b[i + 1] == 0 {
                if b[i + 2] == 1 { starts.append((i, i + 3)); i += 3; continue }
                if i + 3 < b.count, b[i + 2] == 0, b[i + 3] == 1 { starts.append((i, i + 4)); i += 4; continue }
            }
            i += 1
        }
        var nals: [Data] = []
        for (k, s) in starts.enumerated() {
            let end = k + 1 < starts.count ? starts[k + 1].codeStart : b.count
            if end > s.nalStart { nals.append(Data(b[s.nalStart..<end])) }
        }
        return nals
    }

    static func nalType(_ nal: Data) -> UInt8? { nal.first.map { $0 & 0x1f } }

    /// (SPS, PPS) from a config packet, if both are present.
    static func parameterSets(fromConfig config: Data) -> (sps: Data, pps: Data)? {
        let nals = splitAnnexB(config)
        guard let sps = nals.first(where: { nalType($0) == 7 }), let pps = nals.first(where: { nalType($0) == 8 }) else { return nil }
        return (sps, pps)
    }

    /// AVCC (4-byte big-endian length prefixes) for a frame, dropping in-band SPS/PPS/AUD —
    /// the format description already carries the parameter sets.
    static func avcc(fromAnnexB frame: Data) -> Data {
        var out = Data()
        for nal in splitAnnexB(frame) {
            if let t = nalType(nal), t == 7 || t == 8 || t == 9 { continue }
            out.appendBE(UInt32(nal.count)); out.append(nal)
        }
        return out
    }
}

private extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ v: T) {
        Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) }
    }
    func bigEndianUInt32() -> UInt32 { reduce(0) { ($0 << 8) | UInt32($1) } }
    func bigEndianUInt64() -> UInt64 { reduce(0) { ($0 << 8) | UInt64($1) } }
}
