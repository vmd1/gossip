import Foundation
import VideoToolbox
import CoreMedia

/// Decodes a raw, Annex-B-framed H.264 elementary stream (exactly what `adb
/// exec-out screenrecord --output-format=h264 -` writes to stdout) into
/// `CVPixelBuffer`s using VideoToolbox's `VTDecompressionSession`.
///
/// Usage: feed raw bytes as they arrive from the ADB pipe via `push(_:)` in
/// whatever order/chunking they arrive (no need to align to NAL boundaries —
/// this buffers internally). Decoded frames arrive on `onDecodedFrame`, which
/// fires on an arbitrary VideoToolbox callback queue; hop to main before
/// touching UI (see `ScreenMirrorWindow`, which does).
///
/// Not visually verified end-to-end in this environment — see the unit's PR
/// description for exactly what was and wasn't tested against the real
/// device.
final class H264Decoder {
    var onDecodedFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onError: ((Error) -> Void)?

    private var formatDescription: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?

    private var spsData: Data?
    private var ppsData: Data?

    /// Bytes not yet resolved into complete NAL units.
    private var carryover = Data()

    private var frameCount: Int64 = 0
    /// screenrecord's raw H.264 ES carries no real presentation timestamps;
    /// we synthesize a monotonically increasing nominal clock instead.
    private let timescale: Int32 = 90_000
    private let nominalFrameDuration: Int64 = 90_000 / 30

    func push(_ data: Data) {
        carryover.append(data)
        let nalUnits = Self.splitAnnexB(&carryover)
        for nal in nalUnits {
            handle(nal: nal)
        }
    }

    func reset() {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
        decompressionSession = nil
        formatDescription = nil
        spsData = nil
        ppsData = nil
        carryover.removeAll()
        frameCount = 0
    }

    // MARK: - Annex B parsing

    /// Splits `buffer` into complete NAL units (start codes stripped),
    /// consuming them from `buffer` and leaving any trailing partial NAL
    /// (from the last start code onward) for the next call.
    private static func splitAnnexB(_ buffer: inout Data) -> [Data] {
        let bytes = [UInt8](buffer)
        guard bytes.count > 4 else { return [] }

        var starts: [(offset: Int, codeLength: Int)] = []
        var i = 0
        let end = bytes.count
        while i + 2 < end {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                starts.append((i, 3))
                i += 3
            } else if i + 3 < end, bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                starts.append((i, 4))
                i += 4
            } else {
                i += 1
            }
        }

        guard starts.count >= 2 else { return [] } // need a following start code to know the last NAL's end

        var result: [Data] = []
        for idx in 0..<(starts.count - 1) {
            let nalStart = starts[idx].offset + starts[idx].codeLength
            let nalEnd = starts[idx + 1].offset
            guard nalEnd > nalStart else { continue }
            result.append(Data(bytes[nalStart..<nalEnd]))
        }
        // Keep from the last start code onward — it may still be incomplete.
        let lastStart = starts[starts.count - 1].offset
        buffer = Data(bytes[lastStart...])
        return result
    }

    // MARK: - NAL handling

    private func handle(nal: Data) {
        guard let first = nal.first else { return }
        let nalType = first & 0x1F
        switch nalType {
        case 7: // SPS
            spsData = nal
            tryBuildFormatDescription()
        case 8: // PPS
            ppsData = nal
            tryBuildFormatDescription()
        case 1, 5: // non-IDR / IDR slice
            decode(nal: nal)
        default:
            break // SEI (6), AUD (9), etc. — ignored for v1.
        }
    }

    private func tryBuildFormatDescription() {
        guard let sps = spsData, let pps = ppsData else { return }

        let status: OSStatus = sps.withUnsafeBytes { spsRaw -> OSStatus in
            pps.withUnsafeBytes { ppsRaw -> OSStatus in
                let pointers: [UnsafePointer<UInt8>] = [
                    spsRaw.bindMemory(to: UInt8.self).baseAddress!,
                    ppsRaw.bindMemory(to: UInt8.self).baseAddress!,
                ]
                let sizes: [Int] = [sps.count, pps.count]
                var formatDesc: CMVideoFormatDescription?
                let result = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDesc
                )
                if result == noErr {
                    self.formatDescription = formatDesc
                }
                return result
            }
        }

        guard status == noErr, let formatDescription else {
            onError?(NSError(domain: "H264Decoder", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to build format description from SPS/PPS"]))
            return
        }
        setupDecompressionSession(formatDesc: formatDescription)
    }

    private func setupDecompressionSession(formatDesc: CMVideoFormatDescription) {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]

        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: h264DecoderOutputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &session
        )
        guard status == noErr, let session else {
            onError?(NSError(domain: "H264Decoder", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to create VTDecompressionSession"]))
            return
        }
        decompressionSession = session
    }

    private func decode(nal: Data) {
        guard let formatDescription, let session = decompressionSession else { return }

        // Re-frame Annex-B -> AVCC (4-byte big-endian length prefix instead of a start code),
        // which is what CMSampleBuffer/VideoToolbox expect.
        var length = UInt32(nal.count).bigEndian
        var avcc = Data(bytes: &length, count: 4)
        avcc.append(nal)
        let avccLength = avcc.count

        var blockBuffer: CMBlockBuffer?
        var blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avccLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avccLength,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else { return }

        blockStatus = avcc.withUnsafeBytes { raw -> OSStatus in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: avccLength)
        }
        guard blockStatus == kCMBlockBufferNoErr else { return }

        frameCount += 1
        let pts = CMTime(value: frameCount * nominalFrameDuration, timescale: timescale)
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: nominalFrameDuration, timescale: timescale),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        let sampleSizes: [Int] = [avccLength]

        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: sampleSizes,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else { return }

        VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            frameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    fileprivate func handleDecodedFrame(imageBuffer: CVImageBuffer?, status: OSStatus, presentationTimeStamp: CMTime) {
        guard status == noErr, let imageBuffer else {
            if status != noErr {
                onError?(NSError(domain: "H264Decoder", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Decode callback reported an error"]))
            }
            return
        }
        onDecodedFrame?(imageBuffer, presentationTimeStamp)
    }
}

/// C-compatible VideoToolbox output callback; trampolines back into the owning `H264Decoder`.
private func h264DecoderOutputCallback(
    decompressionOutputRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTDecodeInfoFlags,
    imageBuffer: CVImageBuffer?,
    presentationTimeStamp: CMTime,
    presentationDuration: CMTime
) {
    guard let refCon = decompressionOutputRefCon else { return }
    let decoder = Unmanaged<H264Decoder>.fromOpaque(refCon).takeUnretainedValue()
    decoder.handleDecodedFrame(imageBuffer: imageBuffer, status: status, presentationTimeStamp: presentationTimeStamp)
}
