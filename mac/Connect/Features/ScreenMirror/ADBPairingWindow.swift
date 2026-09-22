import AppKit
import SwiftUI

/// Plain `NSWindow` hosting the ADB wireless-pairing QR flow. Deliberately
/// NOT a SwiftUI `.sheet()`: this app's menu bar content is hosted in a
/// `MenuBarExtra(.window)` panel, and presenting a `.sheet()` from that
/// panel's content view causes the whole panel to resign key and dismiss the
/// instant a button inside the sheet is pressed (discovered while building
/// this flow — the same reason `ScreenMirrorWindow` is a plain `NSWindow`
/// rather than a sheet). Every new modal surface in this app follows that
/// pattern: a real `NSWindow`, shown with `makeKeyAndOrderFront`.
final class ADBPairingWindow: NSWindow {
    let pairing: ADBWirelessPairing

    init(pairing: ADBWirelessPairing) {
        self.pairing = pairing
        let initialFrame = NSRect(x: 0, y: 0, width: 340, height: 420)

        super.init(
            contentRect: initialFrame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        title = "Pair Android Device"
        isReleasedWhenClosed = false
        center()

        let hosting = NSHostingView(rootView: ADBPairingContentView(pairing: pairing, onDone: { [weak self] in
            self?.close()
        }))
        contentView = hosting
    }

    override func close() {
        pairing.cancel()
        super.close()
    }
}

/// The SwiftUI content hosted inside `ADBPairingWindow`. Mirrors
/// `PairingSheetView`'s state-machine-driven layout, adapted for
/// `ADBWirelessPairing.State`.
struct ADBPairingContentView: View {
    @ObservedObject var pairing: ADBWirelessPairing
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            switch pairing.state {
            case .idle:
                Text("Preparing…")
                ProgressView()

            case .showingQR(_, let qrImage):
                Text("On your phone: Settings → Developer options →\nWireless debugging → Pair device with QR code")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
                Text("Waiting for the phone to scan…")
                    .foregroundStyle(.secondary)
                ProgressView()

            case .waitingForPairing:
                Text("Waiting for the phone to scan…")
                    .foregroundStyle(.secondary)
                ProgressView()

            case .pairing:
                Text("Pairing…")
                    .font(.headline)
                ProgressView()

            case .waitingForConnect:
                Text("Paired. Waiting for the connection to come up…")
                    .foregroundStyle(.secondary)
                ProgressView()

            case .connecting:
                Text("Connecting…")
                    .font(.headline)
                ProgressView()

            case .connected(let serial, let verified):
                Text("Connected")
                    .font(.headline)
                Text(serial)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if verified {
                    Label("Verified: matches your paired device", systemImage: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                } else {
                    Label("Device connected", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                Button("Done") { onDone() }
                    .keyboardShortcut(.defaultAction)

            case .failed(let reason):
                Text("Pairing failed")
                    .font(.headline)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") { pairing.start() }
                Button("Close") { onDone() }
            }
        }
        .padding(24)
        .frame(width: 340)
        .onAppear {
            if case .idle = pairing.state {
                pairing.start()
            }
        }
    }
}
