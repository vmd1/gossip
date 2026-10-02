import Foundation
import Combine

/// A feature the user can turn off on *this* device (Settings window). Every feature is on by
/// default. Turning one off makes this device stop taking part in it entirely: outgoing messages
/// for it are never sent and incoming ones are dropped (see `isMessageAllowed`), plus local
/// triggers that don't go through messages (e.g. Lock-on-Leave's BLE trigger) are skipped.
enum Feature: String, CaseIterable, Identifiable {
    case clipboard, dnd, notifications, media, screenMirroring, lockOnLeave, hotspot, findDevice, battery, universalControl

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clipboard: return "Clipboard"
        case .dnd: return "Do Not Disturb"
        case .notifications: return "Notifications"
        case .media: return "Media controls"
        case .screenMirroring: return "Screen mirroring"
        case .lockOnLeave: return "Lock on leave"
        case .hotspot: return "Instant Hotspot"
        case .findDevice: return "Find my device"
        case .battery: return "Battery sync"
        case .universalControl: return "Universal Control"
        }
    }

    var detail: String {
        switch self {
        case .clipboard: return "Copy on one device, paste on another."
        case .dnd: return "Keep Focus / Do Not Disturb in sync with your devices."
        case .notifications: return "Show your phone's notifications here and reply to them."
        case .media: return "See what's playing on your phone and control it."
        case .screenMirroring: return "Mirror and control your phone's screen, with audio."
        case .lockOnLeave: return "Lock this Mac when your phone walks out of range."
        case .hotspot: return "Join your phone's hotspot from this Mac with one click."
        case .findDevice: return "Let paired devices make this Mac ring so you can find it, and ring theirs."
        case .battery: return "Share this Mac's battery level and get low-battery alerts for paired devices."
        case .universalControl: return "Push the pointer off a screen edge to use this Mac's mouse and keyboard on your tablets and phones."
        }
    }

    /// Envelope `type` prefixes this feature owns. `screen.` is deliberately absent: screen
    /// mirroring is gated inside `ScreenMirrorController`, so a refused request still gets an
    /// answer instead of silence.
    var messagePrefixes: [String] {
        switch self {
        case .clipboard: return ["clipboard."]
        case .dnd: return ["dnd."]
        case .notifications: return ["notification."]
        case .media: return ["media."]
        case .screenMirroring: return []
        case .lockOnLeave: return ["lock_on_leave."]
        case .hotspot: return ["hotspot."]
        case .findDevice: return ["device."]
        case .battery: return ["battery."]
        case .universalControl: return ["control."]
        }
    }
}

/// Per-device feature toggles, persisted in `UserDefaults` (never sent over the wire — each
/// device decides for itself). Mirrors Android's `FeatureSettings`. Thread-safe: read from
/// transport queues, written from the UI.
final class FeatureSettings: ObservableObject {
    static let shared = FeatureSettings()

    /// Bumps on the main thread whenever a toggle changes, so SwiftUI views refresh.
    @Published private(set) var version = 0

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var disabled: Set<Feature>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        disabled = Set(Feature.allCases.filter { (defaults.object(forKey: Self.key($0)) as? Bool) == false })
    }

    private static func key(_ feature: Feature) -> String { "feature.\(feature.rawValue).enabled" }

    func isEnabled(_ feature: Feature) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !disabled.contains(feature)
    }

    func setEnabled(_ feature: Feature, _ enabled: Bool) {
        lock.lock()
        if enabled { disabled.remove(feature) } else { disabled.insert(feature) }
        lock.unlock()
        defaults.set(enabled, forKey: Self.key(feature))
        if Thread.isMainThread { version += 1 } else { DispatchQueue.main.async { self.version += 1 } }
    }

    /// The feature that owns an envelope `type`, if any (`handshake.`, `presence.`, `trust.`, `screen.` etc. are unowned).
    static func feature(forMessageType type: String) -> Feature? {
        Feature.allCases.first { $0.messagePrefixes.contains { type.hasPrefix($0) } }
    }

    /// `false` when `type` belongs to a feature this device has turned off. Applied to both
    /// outgoing sends and incoming deliveries; relaying other devices' messages is unaffected.
    func isMessageAllowed(type: String) -> Bool {
        guard let feature = Self.feature(forMessageType: type) else { return true }
        return isEnabled(feature)
    }
}
