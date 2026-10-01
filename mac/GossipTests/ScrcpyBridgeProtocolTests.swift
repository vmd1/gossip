import XCTest
@testable import Gossip

final class ScrcpyBridgeProtocolTests: XCTestCase {
    // MARK: Bridge messages

    func testParsesVideoPacket() {
        var d = Data([0x00])
        d.append(contentsOf: [0x20, 0, 0, 0, 0, 0, 0, 0x05]) // key-frame flag + pts 5
        d.append(contentsOf: [0, 0, 0, 1, 0x65, 0xAA])
        guard case .video(let flags, let payload)? = BridgeMessage.parse(d) else { return XCTFail("not video") }
        XCTAssertEqual(flags, BridgeMessage.keyFrameFlag | 5)
        XCTAssertEqual(payload, Data([0, 0, 0, 1, 0x65, 0xAA]))
    }

    func testParsesSizeAndDeviceMessageAndRejectsGarbage() {
        XCTAssertEqual(BridgeMessage.parse(Data([0x01, 0, 0, 2, 0x40, 0, 0, 5, 0])), .size(width: 576, height: 1280))
        XCTAssertEqual(BridgeMessage.parse(Data([0x02, 9, 8])), .deviceMessage(Data([9, 8])))
        XCTAssertEqual(BridgeMessage.parse(Data([0x03, 0, 0, 0, 0, 0, 0, 0, 1, 0xAA, 0xBB, 0xCC, 0xDD])), .audio(Data([0xAA, 0xBB, 0xCC, 0xDD])))
        XCTAssertNil(BridgeMessage.parse(Data([0x03, 0, 0, 0, 0, 0, 0, 0, 1]))) // no payload
        XCTAssertNil(BridgeMessage.parse(Data()))
        XCTAssertNil(BridgeMessage.parse(Data([0x00, 1, 2]))) // truncated pts
        XCTAssertNil(BridgeMessage.parse(Data([0x01, 1, 2, 3])))
        XCTAssertNil(BridgeMessage.parse(Data([0x7f, 1])))
    }

    func testConfigFlagIsBit62AndKeyFrameIsBit61() { // scrcpy 4.1, observed on-device
        XCTAssertEqual(BridgeMessage.configFlag, 0x4000_0000_0000_0000)
        XCTAssertEqual(BridgeMessage.keyFrameFlag, 0x2000_0000_0000_0000)
    }

    func testStreamHeader() {
        let json = #"{"codec":"h264","width":576,"height":1280,"deviceName":"SM-S711B"}"#
        XCTAssertEqual(BridgeStreamHeader.parse(Data(json.utf8)),
                       BridgeStreamHeader(codec: "h264", width: 576, height: 1280, deviceName: "SM-S711B"))
        XCTAssertNil(BridgeStreamHeader.parse(Data("nope".utf8)))
        let withAudio = #"{"codec":"h264","width":1,"height":2,"deviceName":"x","audio":{"codec":"raw","sampleRate":48000,"channels":2,"format":"s16le"}}"#
        XCTAssertEqual(BridgeStreamHeader.parse(Data(withAudio.utf8))?.audio, .init(sampleRate: 48000, channels: 2))
        let nullAudio = #"{"codec":"h264","width":1,"height":2,"deviceName":"x","audio":null}"#
        XCTAssertNil(BridgeStreamHeader.parse(Data(nullAudio.utf8))?.audio)
        let opus = #"{"codec":"h264","width":1,"height":2,"audio":{"codec":"opus","sampleRate":48000,"channels":2,"format":"s16le"}}"#
        XCTAssertNil(BridgeStreamHeader.parse(Data(opus.utf8))?.audio) // only raw PCM is supported
    }

    // MARK: scrcpy control encoding (layouts verified against the real 4.1 server)

    func testTouchLayout() {
        let d = ScrcpyControl.touch(.down, x: 354, y: 1050, width: 576, height: 1280)
        XCTAssertEqual(d.count, 32)
        XCTAssertEqual([UInt8](d), [2, 0] + [0, 0, 0, 0, 0, 0, 0, 0]       // type, action, pointer id
            + [0, 0, 1, 0x62] + [0, 0, 4, 0x1A]                              // x=354, y=1050
            + [2, 0x40] + [5, 0]                                             // 576 x 1280
            + [0xff, 0xff] + [0, 0, 0, 0] + [0, 0, 0, 0])                    // pressure, buttons
        XCTAssertEqual([UInt8](ScrcpyControl.touch(.up, x: 1, y: 1, width: 2, height: 2))[26..<28], [0, 0]) // up = no pressure
    }

    func testScrollLayoutAndClamping() {
        let d = ScrcpyControl.scroll(x: 288, y: 640, width: 576, height: 1280, horizontal: 0, vertical: -100)
        XCTAssertEqual(d.count, 21)
        XCTAssertEqual(d[0], 3)
        XCTAssertEqual([UInt8](d[15..<17]), [0x80, 0x01]) // -32767 (clamped to -16 notches)
    }

    func testKeycodeAndText() {
        XCTAssertEqual([UInt8](ScrcpyControl.keycode(26, down: true)), [0, 0, 0, 0, 0, 26, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(ScrcpyControl.keyPress(4).count, 28)
        XCTAssertEqual([UInt8](ScrcpyControl.text("hi")!), [1, 0, 0, 0, 2, 0x68, 0x69])
        XCTAssertNil(ScrcpyControl.text(""))
        let long = ScrcpyControl.text(String(repeating: "é", count: 400))! // multi-byte: never split mid-character
        XCTAssertLessThanOrEqual(long.count - 5, 300)
        XCTAssertNotNil(String(data: long.dropFirst(5), encoding: .utf8))
        XCTAssertEqual([UInt8](ScrcpyControl.resetVideo), [17])
    }

    // MARK: H.264

    func testSplitsMixedStartCodes() {
        let stream = Data([0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 4, 5, 6])
        XCTAssertEqual(H264.splitAnnexB(stream), [Data([0x67, 1, 2]), Data([0x68, 3]), Data([0x65, 4, 5, 6])])
        XCTAssertEqual(H264.splitAnnexB(Data([1, 2, 3])), [])
    }

    func testParameterSetsAndAVCC() {
        let config = Data([0, 0, 0, 1, 0x67, 0xAA, 0xBB, 0, 0, 0, 1, 0x68, 0xCC])
        let sets = H264.parameterSets(fromConfig: config)
        XCTAssertEqual(sets?.sps, Data([0x67, 0xAA, 0xBB]))
        XCTAssertEqual(sets?.pps, Data([0x68, 0xCC]))
        XCTAssertNil(H264.parameterSets(fromConfig: Data([0, 0, 0, 1, 0x67, 1])))

        // in-band SPS/PPS/AUD are dropped, slices get 4-byte big-endian length prefixes
        let frame = Data([0, 0, 0, 1, 0x09, 0xF0, 0, 0, 0, 1, 0x67, 1, 0, 0, 0, 1, 0x65, 7, 8])
        XCTAssertEqual(H264.avcc(fromAnnexB: frame), Data([0, 0, 0, 3, 0x65, 7, 8]))
    }

    // MARK: Bridge URL

    func testWebSocketURLForIPv4AndIPv6LinkLocal() {
        XCTAssertEqual(ScreenBridgeClient.webSocketURL(host: "192.168.0.122", port: 43417)?.absoluteString, "ws://192.168.0.122:43417/screen")
        XCTAssertEqual(ScreenBridgeClient.webSocketURL(host: "fe80::1%en0", port: 9)?.absoluteString, "ws://[fe80::1%25en0]:9/screen")
    }
}
