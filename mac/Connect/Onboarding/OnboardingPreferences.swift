import Foundation

/// Plain `UserDefaults`-backed onboarding state — just a completion flag. Nothing here is
/// sensitive or ever crosses the wire, unlike `TrustedDevicesStore`/`IdentityKeyStore`, so
/// there's no need for Keychain. Mirrors Android's `OnboardingPreferences`.
enum OnboardingPreferences {
    private static let completedKey = "onboarding.completed"

    static var isCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: completedKey) }
        set { UserDefaults.standard.set(newValue, forKey: completedKey) }
    }
}
