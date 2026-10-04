import XCTest
@testable import Gossip

final class LoggingRedactionTests: XCTestCase {
    func testRedactsAddressesButLeavesIdsAndTimesAlone() {
        XCTAssertEqual(redactAddresses("Connect to 192.168.0.122:7913 failed"), "Connect to <address>:7913 failed")
        XCTAssertEqual(redactAddresses("peer fe80::1%en0 reset"), "peer <address> reset")
        XCTAssertEqual(redactAddresses("peer 2001:db8:0:0:0:0:0:1 reset"), "peer <address> reset")
        let id = "c4f7555f-b505-4ee1-8d95-963ad5cb39f9"
        XCTAssertEqual(redactAddresses("device \(id) at 16:09:44"), "device \(id) at 16:09:44")
    }
}
