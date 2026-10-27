import XCTest
@testable import Gossip
import GossipCoreKit

final class MediaControlManagerTests: XCTestCase {

    func testParseNowPlayingDecodesFullPayload() throws {
        let artBytes = Data("cover-art-bytes".utf8)
        let payload: JSONValue = .object([
            "title": .string("Song Title"),
            "artist": .string("An Artist"),
            "artBase64": .string(artBytes.base64EncodedString()),
            "isPlaying": .bool(true),
            "positionMs": .number(15000),
            "durationMs": .number(210000),
            "packageName": .string("com.spotify.music")
        ])

        let state = MediaControlManager.parseNowPlaying(payload)

        XCTAssertEqual(state?.title, "Song Title")
        XCTAssertEqual(state?.artist, "An Artist")
        XCTAssertEqual(state?.artworkData, artBytes)
        XCTAssertEqual(state?.isPlaying, true)
        XCTAssertEqual(state?.positionMs, 15000)
        XCTAssertEqual(state?.durationMs, 210000)
        XCTAssertEqual(state?.packageName, "com.spotify.music")
    }

    func testOnlyReachableDevicesShowACard() {
        XCTAssertEqual(MediaControlManager.shownDevices(reported: ["a", "b"], reachable: ["b", "c"]), ["b"])
        XCTAssertTrue(MediaControlManager.shownDevices(reported: ["a"], reachable: []).isEmpty)
    }

    func testParseNowPlayingHandlesMissingOptionalArt() throws {
        let payload: JSONValue = .object([
            "title": .string("T"),
            "artist": .string("A"),
            "isPlaying": .bool(false),
            "positionMs": .number(0),
            "durationMs": .number(0),
            "packageName": .string("com.example")
        ])

        let state = MediaControlManager.parseNowPlaying(payload)

        XCTAssertNotNil(state)
        XCTAssertNil(state?.artworkData)
        XCTAssertEqual(state?.isPlaying, false)
    }

    func testParseNowPlayingReturnsNilWhenRequiredFieldsMissing() throws {
        let payload: JSONValue = .object(["artist": .string("A")])
        XCTAssertNil(MediaControlManager.parseNowPlaying(payload))
    }

    func testCommandPayloadWithoutSeek() throws {
        let payload = MediaControlManager.commandPayload(action: .play, seekMs: nil)
        XCTAssertEqual(payload["action"]?.stringValue, "play")
        XCTAssertNil(payload["seekMs"])
    }

    func testCommandPayloadWithSeek() throws {
        let payload = MediaControlManager.commandPayload(action: .pause, seekMs: 4200)
        XCTAssertEqual(payload["action"]?.stringValue, "pause")
        if case .number(let n) = payload["seekMs"] {
            XCTAssertEqual(n, 4200)
        } else {
            XCTFail("expected seekMs to be a number")
        }
    }

    func testVolumePayloadIsSteppedOnce() throws {
        let payload = MediaControlManager.volumePayload(up: false, commandId: "vol-1")
        XCTAssertEqual(payload["direction"]?.stringValue, "down")
        let json = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        let guardLogic = GossipCoreKit.VolumeGuard()
        XCTAssertEqual(try guardLogic.accept(payloadJson: json), .down)
        XCTAssertNil(try guardLogic.accept(payloadJson: json), "the same step is taken once")
    }
}
