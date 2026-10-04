import XCTest
@testable import Gossip

final class InboundRateLimiterTests: XCTestCase {
    func testAllowsABurstUpToTheLimitThenRefusesUntilTheWindowPasses() {
        var l = InboundRateLimiter(limitPerSecond: 3)
        for _ in 0..<3 { XCTAssertTrue(l.allow(now: 100)) }
        XCTAssertFalse(l.allow(now: 100.5))
        XCTAssertTrue(l.allow(now: 101.1))
    }
}
