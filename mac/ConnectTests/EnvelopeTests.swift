import XCTest
@testable import Connect

final class EnvelopeTests: XCTestCase {
    func testEncodeDecodeRoundTrip() throws {
        let envelope = Envelope(
            type: "presence.online",
            senderId: "device-abc",
            recipientId: nil,
            broadcast: true,
            payload: .object(["deviceName": .string("Vivaan's MacBook")])
        )

        let data = try envelope.encoded()
        let decoded = try Envelope.decode(data)

        XCTAssertEqual(decoded.type, "presence.online")
        XCTAssertEqual(decoded.senderId, "device-abc")
        XCTAssertEqual(decoded.broadcast, true)
        XCTAssertEqual(decoded.v, 1)
        XCTAssertEqual(decoded.payload["deviceName"]?.stringValue, "Vivaan's MacBook")
        XCTAssertEqual(decoded.namespace, "presence")
    }
}
