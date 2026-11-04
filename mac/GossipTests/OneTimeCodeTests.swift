import XCTest
@testable import Gossip

final class OneTimeCodeTests: XCTestCase {
    private struct Case: Decodable { let title: String; let body: String; let code: String? }

    /// The shared cases (`schema/otp-cases.json`) the Android detector passes too.
    func testSharedCases() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("schema/otp-cases.json")
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            XCTAssertEqual(OneTimeCode.detect(title: c.title, body: c.body), c.code, c.body)
        }
    }
}
