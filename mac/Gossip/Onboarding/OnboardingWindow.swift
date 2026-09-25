import SwiftUI
import AppKit
import UserNotifications

/// Hosts `OnboardingView` in a plain `NSWindow`, same reasoning as `PairingWindow`/
/// `DNDSetupWindow` — see `PairingWindow`'s doc comment for why not a SwiftUI `.sheet`.
/// Shown automatically on first launch (from `ConnectApp.init()`, unconditionally — not
/// from a menu-bar `.onAppear`, matching the established lesson in this codebase that a
/// `.menuBarExtraStyle(.window)` scene's content only composes once the user opens the
/// tray, which is too late for a first-run flow) and re-openable via "Run Setup Again…".
final class OnboardingWindow: NSWindow {
    init(
        onPairNewDevice: @escaping () -> Void,
        onOpenDNDSetup: @escaping () -> Void,
        notificationAuthorizationStatus: @escaping () -> UNAuthorizationStatus,
        onOpenNotificationSettings: @escaping () -> Void
    ) {
        let initialFrame = NSRect(x: 0, y: 0, width: 420, height: 480)
        super.init(
            contentRect: initialFrame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "Set up Gossip"
        isReleasedWhenClosed = false

        let hostingView = NSHostingView(
            rootView: OnboardingView(
                onPairNewDevice: onPairNewDevice,
                onOpenDNDSetup: onOpenDNDSetup,
                notificationAuthorizationStatus: notificationAuthorizationStatus,
                onOpenNotificationSettings: onOpenNotificationSettings,
                onFinish: { [weak self] in
                    OnboardingPreferences.isCompleted = true
                    self?.close()
                }
            )
        )
        contentView = hostingView
        center()
    }
}
