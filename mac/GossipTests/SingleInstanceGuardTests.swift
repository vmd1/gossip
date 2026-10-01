import XCTest
@testable import Gossip

final class SingleInstanceGuardTests: XCTestCase {
    func testSecondProcessCannotTakeTheLockWhileFirstHoldsIt() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gossip-lock-\(UUID().uuidString)/instance.lock")
        XCTAssertTrue(SingleInstanceGuard.acquire(lockURL: url))
        XCTAssertTrue(SingleInstanceGuard.acquire(lockURL: url), "idempotent for the holder")
        // A second *process* is simulated with a fresh descriptor: flock locks are per open-file-description.
        let fd = open(url.path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertNotEqual(flock(fd, LOCK_EX | LOCK_NB), 0, "lock must be held by the first instance")
        close(fd)
    }
}
