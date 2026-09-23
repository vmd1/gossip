import SwiftUI

/// One-time onboarding/settings screen walking the user through the four Shortcuts
/// they must create by hand so `DNDSyncManager` can bridge Focus/DND state with the
/// paired Android device. macOS has no public API for reading or setting Focus state,
/// so none of this can be auto-provisioned — see `DNDSyncManager` for how each of these
/// is consumed.
struct DNDSetupView: View {
    /// Hosted in a plain `NSWindow` (`DNDSetupWindow`), not a `.sheet` — see
    /// the comment on `PairingSheetView.onDismiss` for why `.sheet` doesn't
    /// work inside a `.menuBarExtraStyle(.window)` content view.
    var onDismiss: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Do Not Disturb Sync Setup")
                    .font(.title2)
                    .bold()

                Text(
                    "macOS doesn't let apps read or change Focus/Do Not Disturb state " +
                    "directly. Connect bridges this through the Shortcuts app instead. " +
                    "Create the four Shortcuts below, exactly as named — this only " +
                    "needs to be done once."
                )
                .foregroundStyle(.secondary)

                Divider()

                Text("Reporting: tell your phone when this Mac's Focus changes")
                    .font(.headline)

                shortcutStep(
                    title: "Automation 1",
                    detail: "Shortcuts → Automation → “+” → “When Focus is turned on” " +
                        "(any Focus) → Action: “Open URL”"
                )
                urlBlock("connect://dnd?state=on")

                shortcutStep(
                    title: "Automation 2",
                    detail: "Shortcuts → Automation → “+” → “When Focus is turned off” " +
                        "→ Action: “Open URL”"
                )
                urlBlock("connect://dnd?state=off")

                Text(
                    "For both automations, turn off “Ask Before Running” so they fire " +
                    "silently."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Divider()

                Text("Control: let your phone turn this Mac's Focus on/off")
                    .font(.headline)

                shortcutStep(
                    title: "Shortcut 1 — name it exactly:",
                    detail: nil
                )
                nameBlock("Connect Turn On DND")
                Text("Add action: “Set Focus” → On")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                shortcutStep(
                    title: "Shortcut 2 — name it exactly:",
                    detail: nil
                )
                nameBlock("Connect Turn Off DND")
                Text("Add action: “Set Focus” → Off")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(
                    "These two (non-automation) Shortcuts are run on demand — by name " +
                    "— when your phone asks this Mac to change its Focus state."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Divider()

                HStack {
                    Spacer()
                    Button("Done") {
                        onDismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .frame(width: 420, height: 520)
    }

    @ViewBuilder
    private func shortcutStep(title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).fontWeight(.semibold)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func urlBlock(_ url: String) -> some View {
        Text(url)
            .font(.system(.body, design: .monospaced))
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.12))
            .cornerRadius(6)
    }

    @ViewBuilder
    private func nameBlock(_ name: String) -> some View {
        Text("\u{201C}\(name)\u{201D}")
            .font(.system(.body, design: .monospaced))
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.12))
            .cornerRadius(6)
    }
}
