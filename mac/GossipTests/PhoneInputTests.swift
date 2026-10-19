import XCTest
@testable import Gossip

final class PhoneInputTests: XCTestCase {
    private final class Recorder: PhoneInputInjector {
        var actions: [PhoneInputAction] = []
        func perform(_ action: PhoneInputAction) { actions.append(action) }
    }

    private func envelope(_ payload: [String: JSONValue]) -> Envelope {
        Envelope(type: "peripheral.input", senderId: "phone", recipientId: "mac", ttl: 4, payload: .object(payload))
    }

    func testParsesEveryKind() {
        XCTAssertEqual(PhoneInputAction.parse(.object(["kind": .string("move"), "dx": .number(3), "dy": .number(-4)])), .move(dx: 3, dy: -4))
        XCTAssertEqual(PhoneInputAction.parse(.object(["kind": .string("click"), "button": .number(1), "count": .number(2)])), .click(button: 1, count: 2))
        XCTAssertEqual(PhoneInputAction.parse(.object(["kind": .string("button"), "button": .number(0), "down": .bool(true)])), .button(button: 0, down: true))
        XCTAssertEqual(PhoneInputAction.parse(.object(["kind": .string("scroll"), "dx": .number(0), "dy": .number(9)])), .scroll(dx: 0, dy: 9))
        XCTAssertEqual(PhoneInputAction.parse(.object(["kind": .string("key"), "key": .string("return")])), .key(name: "return", down: nil))
        XCTAssertEqual(PhoneInputAction.parse(.object(["kind": .string("text"), "text": .string("héllo")])), .text("héllo"))
    }

    func testRejectsMalformedAndClamps() {
        XCTAssertNil(PhoneInputAction.parse(.object(["kind": .string("move"), "dx": .number(1)])))
        XCTAssertNil(PhoneInputAction.parse(.object(["kind": .string("key"), "key": .string("f13")])))
        XCTAssertNil(PhoneInputAction.parse(.object(["kind": .string("text"), "text": .string("")])))
        XCTAssertNil(PhoneInputAction.parse(.object(["kind": .string("launch-missiles")])))
        XCTAssertNil(PhoneInputAction.parse(.object(["kind": .string("move"), "dx": .number(.infinity), "dy": .number(0)])))
        XCTAssertEqual(PhoneInputAction.parse(.object(["kind": .string("move"), "dx": .number(1e9), "dy": .number(-1e9)])),
                       .move(dx: PhoneInputAction.maxDelta, dy: -PhoneInputAction.maxDelta))
        if case .text(let t)? = PhoneInputAction.parse(.object(["kind": .string("text"), "text": .string(String(repeating: "a", count: 5000))])) {
            XCTAssertEqual(t.count, PhoneInputAction.maxTextLength)
        } else { XCTFail() }
    }

    func testDuplicatesAndStaleMessagesAreIgnored() {
        let recorder = Recorder()
        let manager = PhoneInputManager(injector: recorder)
        let move: (Int, String) -> Envelope = { seq, session in
            self.envelope(["sessionId": .string(session), "seq": .number(Double(seq)), "kind": .string("move"), "dx": .number(1), "dy": .number(1)])
        }
        manager.handle(move(1, "a")); manager.handle(move(1, "a")) // duplicate delivery
        manager.handle(move(3, "a")); manager.handle(move(2, "a")) // late, out of order
        manager.handle(move(1, "b"))                               // a different session starts over
        XCTAssertEqual(recorder.actions.count, 3)
    }

    func testRequiresSessionAndSequence() {
        let recorder = Recorder()
        let manager = PhoneInputManager(injector: recorder)
        manager.handle(envelope(["seq": .number(1), "kind": .string("move"), "dx": .number(1), "dy": .number(1)]))
        manager.handle(envelope(["sessionId": .string("a"), "kind": .string("move"), "dx": .number(1), "dy": .number(1)]))
        XCTAssertTrue(recorder.actions.isEmpty)
    }

    func testSequencerIsBounded() {
        var s = PhoneInputSequencer()
        for i in 0..<(PhoneInputSequencer.maxSessions + 5) { XCTAssertTrue(s.accept(sessionId: "s\(i)", seq: 1)) }
        XCTAssertTrue(s.accept(sessionId: "s0", seq: 1), "the oldest session was evicted")
        XCTAssertFalse(s.accept(sessionId: "s\(PhoneInputSequencer.maxSessions + 4)", seq: 1))
    }

    func testPhoneInputIsOptInAndOwnsItsPrefix() {
        XCTAssertEqual(FeatureSettings.feature(forMessageType: "peripheral.input"), .phoneInput)
        let settings = FeatureSettings(defaults: UserDefaults(suiteName: "pi-\(UUID().uuidString)")!)
        XCTAssertFalse(settings.isMessageAllowed(type: "peripheral.input"))
    }
}
