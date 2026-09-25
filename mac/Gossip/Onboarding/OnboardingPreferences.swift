import Foundation

/// Plain `UserDefaults`-backed onboarding state — just a completion flag. Nothing here is
/// sensitive or ever crosses the wire, unlike `TrustedDevicesStore`/`IdentityKeyStore`, so
/// there's no need for Keychain. Mirrors Android's `OnboardingPreferences`.
enum OnboardingPreferences {
    private static let completedKey = "onboarding.completed"
    private static let autoRequestHotspotKey = "onboarding.autoRequestHotspotEnabled"

    static var isCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: completedKey) }
        set { UserDefaults.standard.set(newValue, forKey: completedKey) }
    }

    /// Whether this Mac automatically requests Instant Hotspot from a nearby, eligible
    /// phone after being offline (no WAN reachability) for a while — see
    /// `docs/ble-hotspot-protocol.md`'s WAN-reachability probe and
    /// `AutoHotspotRequestManager`. Mirrors Android's `OnboardingPreferences.
    /// autoRequestHotspotEnabled`; Mac has no `provideHotspotEnabled` counterpart since a
    /// Mac never provides Instant Hotspot, only requests. Off by default, local-only,
    /// never sent over the wire.
    static var autoRequestHotspotEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: autoRequestHotspotKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoRequestHotspotKey) }
    }
}
