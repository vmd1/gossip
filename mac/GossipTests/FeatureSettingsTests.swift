import XCTest
@testable import Gossip

final class FeatureSettingsTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "FeatureSettingsTests-\(UUID().uuidString)")
    }

    func testEveryFeatureIsOnByDefault() {
        let settings = FeatureSettings(defaults: defaults)
        for feature in Feature.allCases { XCTAssertTrue(settings.isEnabled(feature), "\(feature)") }
    }

    func testToggleIsIndependentAndPersists() {
        let settings = FeatureSettings(defaults: defaults)
        settings.setEnabled(.clipboard, false)
        XCTAssertFalse(settings.isEnabled(.clipboard))
        XCTAssertTrue(settings.isEnabled(.dnd))

        let reloaded = FeatureSettings(defaults: defaults)
        XCTAssertFalse(reloaded.isEnabled(.clipboard))
        XCTAssertTrue(reloaded.isEnabled(.dnd))

        reloaded.setEnabled(.clipboard, true)
        XCTAssertTrue(FeatureSettings(defaults: defaults).isEnabled(.clipboard))
    }

    func testMessageTypesMapToTheirFeature() {
        XCTAssertEqual(FeatureSettings.feature(forMessageType: "clipboard.update"), .clipboard)
        XCTAssertEqual(FeatureSettings.feature(forMessageType: "dnd.update"), .dnd)
        XCTAssertEqual(FeatureSettings.feature(forMessageType: "notification.reply"), .notifications)
        XCTAssertEqual(FeatureSettings.feature(forMessageType: "media.nowplaying"), .media)
        XCTAssertEqual(FeatureSettings.feature(forMessageType: "lock_on_leave.config"), .lockOnLeave)
        XCTAssertEqual(FeatureSettings.feature(forMessageType: "hotspot.state_update"), .hotspot)
        XCTAssertEqual(FeatureSettings.feature(forMessageType: "device.ring"), .findDevice)
        XCTAssertEqual(FeatureSettings.feature(forMessageType: "battery.update"), .battery)
        for unowned in ["handshake.hello", "presence.heartbeat", "trust.roster_update", "screen.start", "screen.ready"] {
            XCTAssertNil(FeatureSettings.feature(forMessageType: unowned), unowned)
        }
    }

    func testDisabledFeatureMessagesAreNotAllowedButOthersAre() {
        let settings = FeatureSettings(defaults: defaults)
        settings.setEnabled(.clipboard, false)
        XCTAssertFalse(settings.isMessageAllowed(type: "clipboard.update"))
        XCTAssertTrue(settings.isMessageAllowed(type: "dnd.update"))
        XCTAssertTrue(settings.isMessageAllowed(type: "trust.roster_update"))
    }

    func testRouterDropsDisabledFeatureAndDeliversTheRest() {
        let settings = FeatureSettings(defaults: defaults)
        let router = MessageRouter(featureSettings: settings)
        var received: [String] = []
        router.register(prefix: "clipboard.") { received.append($0.type) }
        router.register(prefix: "dnd.") { received.append($0.type) }

        settings.setEnabled(.clipboard, false)
        router.route(Envelope(type: "clipboard.update", senderId: "x"))
        router.route(Envelope(type: "dnd.update", senderId: "x"))
        XCTAssertEqual(received, ["dnd.update"])

        settings.setEnabled(.clipboard, true)
        router.route(Envelope(type: "clipboard.update", senderId: "x"))
        XCTAssertEqual(received, ["dnd.update", "clipboard.update"])
    }
}
