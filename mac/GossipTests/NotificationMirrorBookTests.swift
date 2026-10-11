import XCTest
@testable import Gossip

final class NotificationMirrorBookTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func id(_ n: String) -> String { "phone|" + n }
    private let ownsPhone: (String) -> Bool = { $0.hasPrefix("phone|") }

    func testSyncRemovesWhatThePhoneNoLongerHasOnceItIsOldEnough() {
        let book = NotificationMirrorBook()
        book.recordShown(id("old"), at: t0)
        book.recordShown(id("kept"), at: t0)
        book.recordShown(id("fresh"), at: t0.addingTimeInterval(55))
        let outcome = book.applySync(liveIdentifiers: [id("kept")], owns: ownsPhone, now: t0.addingTimeInterval(60))
        XCTAssertEqual(outcome.remove, [id("old")], "fresh is inside the grace window, kept is listed")
        XCTAssertEqual(book.shownIdentifiers, [id("kept"), id("fresh")])
    }

    func testSyncOnlyTouchesTheSendersNotifications() {
        let book = NotificationMirrorBook()
        book.recordShown(id("a"), at: t0)
        book.recordShown("tablet|b", at: t0)
        let outcome = book.applySync(liveIdentifiers: [], owns: ownsPhone, now: t0.addingTimeInterval(60))
        XCTAssertEqual(outcome.remove, [id("a")])
        XCTAssertTrue(book.shownIdentifiers.contains("tablet|b"))
    }

    func testApplyingTheSameSyncTwiceIsANoOp() {
        let book = NotificationMirrorBook()
        book.recordShown(id("a"), at: t0)
        let now = t0.addingTimeInterval(60)
        XCTAssertEqual(book.applySync(liveIdentifiers: [], owns: ownsPhone, now: now).remove, [id("a")])
        XCTAssertEqual(book.applySync(liveIdentifiers: [], owns: ownsPhone, now: now), NotificationMirrorBook.SyncOutcome(remove: [], redismiss: []))
    }

    func testAPostThatArrivesAfterItsRemovalIsStaleButARepostIsNot() {
        let book = NotificationMirrorBook()
        book.recordRemoval(id("a"), at: 5_000)
        XCTAssertTrue(book.isStale(id("a"), postedAt: 4_000), "posted before it was removed: a late delivery")
        XCTAssertTrue(book.isStale(id("a"), postedAt: 5_000))
        XCTAssertFalse(book.isStale(id("a"), postedAt: 6_000), "a genuine new post of the same key")
        XCTAssertFalse(book.isStale(id("other"), postedAt: 1))
    }

    func testALostDismissIsSentAgainWhileThePhoneStillListsIt() {
        let book = NotificationMirrorBook()
        book.recordShown(id("a"), at: t0)
        book.recordDismissedHere(id("a"), at: t0)
        let outcome = book.applySync(liveIdentifiers: [id("a")], owns: ownsPhone, now: t0.addingTimeInterval(60))
        XCTAssertEqual(outcome.redismiss, [id("a")])
        let later = book.applySync(liveIdentifiers: [id("a")], owns: ownsPhone, now: t0.addingTimeInterval(60 + NotificationMirrorBook.dismissRetention))
        XCTAssertTrue(later.redismiss.isEmpty, "forgotten after the retention window")
        let gone = book.applySync(liveIdentifiers: [], owns: ownsPhone, now: t0.addingTimeInterval(30))
        XCTAssertTrue(gone.redismiss.isEmpty)
    }

    func testRemovalForgetsTheShownNotificationSoItIsNotMistakenForADismissal() {
        let book = NotificationMirrorBook()
        book.recordShown(id("a"), at: t0)
        book.recordRemoval(id("a"), at: 10)
        XCTAssertTrue(book.isEmpty)
    }
}
