import SwiftUI
import CoreBluetooth
import UserNotifications

/// First-run guided setup, shown once (`OnboardingPreferences.isCompleted`) and
/// re-enterable later from the menu bar's "Run Setup Again…" button. Chrome around
/// existing mechanisms only — pairing, Bluetooth, notifications, and DND sync setup are
/// all pre-existing features this just sequences into one guided flow for a first-time
/// user, matching the Android onboarding flow's design intent (see
/// `HANDOFF_ONBOARDING_AND_POLISH.md` Phase 2). Mac has no Instant-Hotspot-style
/// privileged-call/mechanism-probing step — there's no Mac-side equivalent gap, per that
/// handoff's own Phase 3 audit note — so this is shorter than Android's counterpart.
struct OnboardingView: View {
    /// Opens the same "Pair New Device…" flow `MenuBarView`'s button does.
    var onPairNewDevice: () -> Void
    /// Opens the same "Do Not Disturb Sync Setup…" window `MenuBarView`'s button does.
    var onOpenDNDSetup: () -> Void
    var notificationAuthorizationStatus: () -> UNAuthorizationStatus
    var onOpenNotificationSettings: () -> Void
    var onFinish: () -> Void

    private enum Step: Int, CaseIterable {
        case otherDevice, permissions, done
    }

    @State private var step: Step = .otherDevice
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProgressView(value: Double(step.rawValue + 1), total: Double(Step.allCases.count))

            Text("Set up Connect")
                .font(.title2)
                .bold()

            // Cross-fade between steps rather than an instant cut, per
            // `docs/design-system.md`'s motion guidance — a real state change (the user
            // just clicked Continue) should read as the UI responding, not just
            // re-rendering.
            Group {
                switch step {
                case .otherDevice:
                    otherDeviceStep
                case .permissions:
                    permissionsStep
                case .done:
                    doneStep
                }
            }
            .transition(.opacity)
            .animation(.default, value: step)
        }
        .padding(24)
        .frame(width: 420)
        .onAppear { notificationStatus = notificationAuthorizationStatus() }
    }

    @ViewBuilder
    private var otherDeviceStep: some View {
        Text("Do you have another device to connect to?")
            .font(.headline)
        Text(
            "Pair with your Android phone or tablet now, or skip and pair later from the " +
            "menu bar."
        )
        .foregroundStyle(.secondary)

        HStack {
            Button("Pair a Device…", action: onPairNewDevice)
            Button("Skip for now") { step = .permissions }
            Spacer()
            Button("Continue") { step = .permissions }
                .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private var permissionsStep: some View {
        Text("A couple of permissions")
            .font(.headline)
        Text(
            "Each of these unlocks one feature. Bluetooth is requested automatically the " +
            "first time it's needed; the others are a click away below."
        )
        .foregroundStyle(.secondary)

        permissionRow(
            title: "Bluetooth",
            status: bluetoothStatusText,
            isGood: CBManager.authorization == .allowedAlways,
            detail: "Detects nearby trusted devices (e.g. for Lock-on-Leave). macOS will " +
                "prompt for this automatically the first time Connect scans — if you " +
                "missed it, allow Bluetooth for Connect in System Settings → Privacy & " +
                "Security → Bluetooth."
        )

        permissionRow(
            title: "Notifications",
            status: notificationStatusText,
            isGood: notificationStatus == .authorized,
            detail: "Lets Connect show status alerts.",
            action: notificationStatus == .denied ? onOpenNotificationSettings : nil,
            actionLabel: "Open Notification Settings…"
        )

        permissionRow(
            title: "Do Not Disturb sync (optional)",
            status: nil,
            isGood: false,
            detail: "macOS has no API for reading Focus state directly — this is a " +
                "one-time Shortcuts setup, a few minutes, fully optional.",
            action: onOpenDNDSetup,
            actionLabel: "Set Up DND Sync…"
        )

        HStack {
            Spacer()
            Button("Continue") { step = .done }
                .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private var doneStep: some View {
        Text("You're all set")
            .font(.headline)
        Text(
            "You can re-run this setup anytime from the menu bar if you grant permissions " +
            "later or get a new device."
        )
        .foregroundStyle(.secondary)
        HStack {
            Spacer()
            Button("Finish", action: onFinish)
                .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        status: String?,
        isGood: Bool,
        detail: String,
        action: (() -> Void)? = nil,
        actionLabel: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).bold()
                if let status {
                    Text(status)
                        .foregroundStyle(isGood ? .green : .secondary)
                        .font(.caption)
                }
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let action, let actionLabel {
                Button(actionLabel, action: action)
            }
        }
        .padding(.vertical, 4)
    }

    private var bluetoothStatusText: String {
        switch CBManager.authorization {
        case .allowedAlways: return "Allowed"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not requested yet"
        @unknown default: return "Unknown"
        }
    }

    private var notificationStatusText: String {
        switch notificationStatus {
        case .authorized, .provisional: return "Allowed"
        case .denied: return "Denied"
        case .notDetermined: return "Not requested yet"
        case .ephemeral: return "Allowed (ephemeral)"
        @unknown default: return "Unknown"
        }
    }
}
