import XCTest
@testable import Gossip

private final class FakeRinger: Ringer {
    var starts = 0, stops = 0
    func start() { starts += 1 }
    func stop() { stops += 1 }
}

final class RingManagerTests: XCTestCase {
    private func ring(_ action: String, _ id: String) -> Envelope {
        Envelope(type: "device.ring", senderId: "peer", recipientId: "me", payload: RingManager.payload(action: action, ringId: id))
    }

    func testStartRingsStopSilencesAndDuplicatesAreNoOps() {
        let ringer = FakeRinger()
        let m = RingManager(transportManager: TransportManager(), ringer: ringer, showsAlert: false)
        m.handle(ring("stop", "x")); XCTAssertEqual(ringer.stops, 0)
        m.handle(ring("start", "a")); m.handle(ring("start", "a")); m.handle(ring("start", "b"))
        XCTAssertTrue(m.isRinging); XCTAssertEqual(ringer.starts, 1)
        m.handle(ring("stop", "c")); XCTAssertFalse(m.isRinging); XCTAssertEqual(ringer.stops, 1)
        m.handle(ring("start", "a"))   // late redelivery of an already-handled start
        XCTAssertFalse(m.isRinging); XCTAssertEqual(ringer.starts, 1)
        m.handle(ring("start", "d")); XCTAssertEqual(ringer.starts, 2)
        m.stopRinging()
    }

    func testAutoStopsAfterTimeout() {
        let ringer = FakeRinger()
        let m = RingManager(transportManager: TransportManager(), ringer: ringer, autoStopAfter: 0.1, showsAlert: false)
        m.handle(ring("start", "a"))
        XCTAssertTrue(m.isRinging)
        let done = expectation(description: "auto-stop")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertFalse(m.isRinging); XCTAssertEqual(ringer.stops, 1)
    }

    func testMalformedMessagesAreIgnored() {
        let ringer = FakeRinger()
        let m = RingManager(transportManager: TransportManager(), ringer: ringer, showsAlert: false)
        m.handle(Envelope(type: "device.ring", senderId: "p"))
        m.handle(Envelope(type: "device.ring", senderId: "p", payload: .object(["action": .string("start")])))
        XCTAssertEqual(ringer.starts, 0)
    }
}

final class BatterySyncManagerTests: XCTestCase {
    private func update(_ from: String, _ level: Int, _ charging: Bool) -> Envelope {
        Envelope(type: "battery.update", senderId: from, broadcast: true,
                 payload: BatterySyncManager.payload(sourceDeviceId: from, state: BatteryState(level: level, isCharging: charging)))
    }

    func testLowBatteryAlertsOncePerEpisodeAndTracksLastWrite() {
        var alerts: [(String, Int)] = []
        let m = BatterySyncManager(transportManager: TransportManager(), readBattery: { nil }, onLowBattery: { alerts.append(($0, $1)) })
        m.handleUpdate(update("a", 19, false)); m.handleUpdate(update("a", 19, false)); m.handleUpdate(update("a", 18, false))
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(m.batteryBySenderId["a"], BatteryState(level: 18, isCharging: false))
        m.handleUpdate(update("a", 25, false)); m.handleUpdate(update("a", 15, false))   // not re-armed yet
        XCTAssertEqual(alerts.count, 1)
        m.handleUpdate(update("a", 40, false)); m.handleUpdate(update("a", 20, false))   // re-armed
        XCTAssertEqual(alerts.count, 2)
        m.handleUpdate(update("b", 5, true))                                              // charging: no alert
        XCTAssertEqual(alerts.count, 2)
    }

    func testMalformedUpdateIsIgnored() {
        let m = BatterySyncManager(transportManager: TransportManager(), readBattery: { nil }, onLowBattery: { _, _ in })
        m.handleUpdate(Envelope(type: "battery.update", senderId: "a", payload: .object(["level": .number(5)])))
        XCTAssertTrue(m.batteryBySenderId.isEmpty)
    }
}
