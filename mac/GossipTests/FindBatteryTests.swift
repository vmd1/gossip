import XCTest
import Combine
@testable import Gossip
import GossipCoreKit

// Both modules declare an `Envelope` (the app's and the core's); these tests mean the app's.
private typealias Envelope = Gossip.Envelope

private final class FakeRinger: Ringer {
    var starts = 0, stops = 0
    func start() { starts += 1 }
    func stop() { stops += 1 }
}

/// A controllable clock for `RingManager`'s auto-stop and expiry (the real ones are 30 s and 35 s).
private final class TestClock { var ms: Int64 = 1_000_000 }

final class RingManagerTests: XCTestCase {
    private func payload(_ action: String, _ id: String) -> JSONValue { .object(["action": .string(action), "ringId": .string(id)]) }
    private func ring(_ action: String, _ id: String) -> Envelope {
        Envelope(type: "device.ring", senderId: "peer", recipientId: "me", payload: payload(action, id))
    }
    private func ringState(_ from: String, _ ringing: Bool) -> Envelope {
        Envelope(type: "device.ring_state", senderId: from, recipientId: "me", payload: .object(["ringing": .bool(ringing)]))
    }
    private func flat(_ sent: [Envelope]) -> [String] {
        sent.map { "\($0.type)>\($0.recipientId ?? "")" + ($0.payload["ringing"]?.boolValue.map { ":\($0)" } ?? ":" + ($0.payload["action"]?.stringValue ?? "")) }
    }
    private func manager(_ ringer: Ringer = FakeRinger(), clock: TestClock = TestClock(), sent: @escaping (Envelope) -> Void = { _ in }) -> RingManager {
        RingManager(transportManager: TransportManager(), ringer: ringer, showsAlert: false, now: { clock.ms }, runsClock: false, sendEnvelope: sent)
    }

    func testStartRingsStopSilencesAndDuplicatesAreNoOps() {
        let ringer = FakeRinger()
        let m = manager(ringer)
        m.handle(ring("stop", "x")); XCTAssertEqual(ringer.stops, 0)
        m.handle(ring("start", "a")); m.handle(ring("start", "a")); m.handle(ring("start", "b"))
        XCTAssertTrue(m.isRinging); XCTAssertEqual(ringer.starts, 1)
        m.handle(ring("stop", "c")); XCTAssertFalse(m.isRinging); XCTAssertEqual(ringer.stops, 1)
        m.handle(ring("start", "a"))   // late redelivery of an already-handled start
        XCTAssertFalse(m.isRinging); XCTAssertEqual(ringer.starts, 1)
        m.handle(ring("start", "d")); XCTAssertEqual(ringer.starts, 2)
        m.stopRinging()
    }

    func testAutoStopsAfterTheCoresTimeout() {
        let ringer = FakeRinger(); let clock = TestClock()
        let m = manager(ringer, clock: clock)
        m.handle(ring("start", "a"))
        XCTAssertTrue(m.isRinging)
        clock.ms += 29_000; m.tick(); XCTAssertTrue(m.isRinging)
        clock.ms += 2_000; m.tick()
        XCTAssertFalse(m.isRinging); XCTAssertEqual(ringer.stops, 1)
    }

    func testMalformedMessagesAreIgnored() {
        let ringer = FakeRinger()
        let m = manager(ringer)
        m.handle(Envelope(type: "device.ring", senderId: "p"))
        m.handle(Envelope(type: "device.ring", senderId: "p", payload: .object(["action": .string("start")])))
        XCTAssertEqual(ringer.starts, 0)
    }

    func testReportsRingStateToRequesterHoweverRingStops() {
        var sent: [Envelope] = []; let clock = TestClock()
        let m = manager(clock: clock) { sent.append($0) }
        m.handle(ring("start", "a")); m.stopRinging()               // local Stop
        XCTAssertEqual(flat(sent), ["device.ring_state>peer:true", "device.ring_state>peer:false"])
        sent.removeAll()
        m.handle(ring("start", "b")); m.handle(ring("stop", "c"))   // stop message
        XCTAssertEqual(flat(sent), ["device.ring_state>peer:true", "device.ring_state>peer:false"])
        sent.removeAll()
        m.handle(ring("stop", "d")); m.handle(ring("start", "b"))   // no-ops send nothing
        XCTAssertTrue(sent.isEmpty)
        m.handle(ring("start", "e"))                                // auto-stop
        clock.ms += 31_000; m.tick()
        XCTAssertEqual(flat(sent), ["device.ring_state>peer:true", "device.ring_state>peer:false"])
    }

    func testToggleRingStartsThenStopsAndTracksPeer() {
        var sent: [Envelope] = []
        let m = manager { sent.append($0) }
        m.toggleRing("phone")
        XCTAssertEqual(m.ringingPeers, ["phone"]); XCTAssertEqual(sent.last?.payload["action"]?.stringValue, "start")
        m.toggleRing("phone")
        XCTAssertTrue(m.ringingPeers.isEmpty); XCTAssertEqual(sent.last?.payload["action"]?.stringValue, "stop")
        XCTAssertEqual(sent.last?.recipientId, "phone")
    }

    func testPeerRingStateUpdatesButtonAndLostReportExpires() {
        let clock = TestClock()
        let m = manager(clock: clock)
        m.handleRingState(ringState("phone", true)); m.handleRingState(ringState("phone", true))
        XCTAssertEqual(m.ringingPeers, ["phone"])
        m.handleRingState(ringState("phone", false)); m.handleRingState(ringState("phone", false))
        XCTAssertTrue(m.ringingPeers.isEmpty)
        m.handleRingState(ringState("tablet", true))                // the "stopped" report never arrives
        clock.ms += 36_000; m.tick()
        XCTAssertTrue(m.ringingPeers.isEmpty)
    }
}

final class BatterySyncManagerTests: XCTestCase {
    private func slot(_ level: Int, _ charging: Bool) -> String {
        GossipCoreKit.batteryPayload(state: GossipCoreKit.BatteryState(level: UInt8(level), isCharging: charging))
    }

    func testLowBatteryAlertsOncePerEpisodeAndTracksLastWrite() {
        var alerts: [(String, Int)] = []
        let m = BatterySyncManager(transportManager: TransportManager(), readBattery: { nil }, onLowBattery: { alerts.append(($0, $1)) })
        m.handleSlot(deviceId: "a", valueJSON: slot(19, false)); m.handleSlot(deviceId: "a", valueJSON: slot(19, false)); m.handleSlot(deviceId: "a", valueJSON: slot(18, false))
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(m.batteryBySenderId["a"], BatteryState(level: 18, isCharging: false))
        m.handleSlot(deviceId: "a", valueJSON: slot(25, false)); m.handleSlot(deviceId: "a", valueJSON: slot(15, false))   // not re-armed yet
        XCTAssertEqual(alerts.count, 1)
        m.handleSlot(deviceId: "a", valueJSON: slot(40, false)); m.handleSlot(deviceId: "a", valueJSON: slot(20, false))   // re-armed
        XCTAssertEqual(alerts.count, 2)
        m.handleSlot(deviceId: "b", valueJSON: slot(5, true))                                                              // charging: no alert
        XCTAssertEqual(alerts.count, 2)
    }

    func testMalformedUpdateIsIgnoredAndAClearedSlotForgetsTheDevice() {
        let m = BatterySyncManager(transportManager: TransportManager(), readBattery: { nil }, onLowBattery: { _, _ in })
        m.handleSlot(deviceId: "a", valueJSON: #"{"level":5}"#)
        XCTAssertTrue(m.batteryBySenderId.isEmpty)
        m.handleSlot(deviceId: "a", valueJSON: slot(50, false))
        XCTAssertNotNil(m.batteryBySenderId["a"])
        m.handleSlot(deviceId: "a", valueJSON: nil)
        XCTAssertNil(m.batteryBySenderId["a"], "a revoked device's reading is dropped")
    }
}

final class HotspotStateManagerThreadingTests: XCTestCase {
    /// Regression: a `hotspot.state` slot update arrives on the transport's background queue; publishing
    /// the state there crashed the app (AppKit aborts when the menu-bar item is rebuilt off-main).
    func testStateUpdateFromBackgroundQueueIsPublishedOnMainThread() {
        let transport = TransportManager()
        let manager = HotspotStateManager(transportManager: transport)
        let published = expectation(description: "published")
        var publishedOnMain: Bool?
        let cancellable = manager.$hotspotStateBySenderId.dropFirst().sink { _ in
            publishedOnMain = Thread.isMainThread
            published.fulfill()
        }
        let value = GossipCoreKit.hotspotStatePayload(enabled: true, ssid: "net")
        DispatchQueue.global().async { manager.handleSlot(deviceId: "phone", valueJSON: value) }
        wait(for: [published], timeout: 2)
        XCTAssertEqual(publishedOnMain, true)
        XCTAssertEqual(manager.hotspotStateBySenderId["phone"]?.enabled, true)
        cancellable.cancel()
    }
}
