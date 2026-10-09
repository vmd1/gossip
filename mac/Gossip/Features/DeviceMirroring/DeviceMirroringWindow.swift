import SwiftUI
import AppKit

/// The "Device Mirroring" window: every paired phone and tablet with its connection state and a Mirror /
/// Stop button. Opened from the Device Mirroring launcher app (`connect://mirror`) and works on the same
/// `ScreenMirrorController` as the menu-bar panel's mirror icon.
struct DeviceMirroringView: View {
    @ObservedObject var trustedDevicesStore: TrustedDevicesStore
    @ObservedObject var transportManager: TransportManager
    @ObservedObject var screenMirrorController: ScreenMirrorController
    @ObservedObject var batterySyncManager: BatterySyncManager
    @ObservedObject var featureSettings: FeatureSettings

    private var rows: [MirrorRow] {
        DeviceMirroringRows.rows(
            devices: trustedDevicesStore.devices,
            connectedIds: transportManager.connectedDeviceIds,
            meshIds: transportManager.meshReachableDeviceIds,
            relayedIds: transportManager.relayedDeviceIds,
            batteries: batterySyncManager.batteryBySenderId
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Device Mirroring").font(.title2.weight(.semibold))
            Text("Choose a device to mirror its screen to this Mac.").foregroundStyle(.secondary).font(.callout)

            if !featureSettings.isEnabled(.screenMirroring) {
                Text("Screen mirroring is turned off in Gossip's Settings.").foregroundStyle(.orange).font(.callout)
            }
            if let error = screenMirrorController.lastError {
                Text(error).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true)
            }

            if rows.isEmpty {
                Spacer()
                Text("No paired phones or tablets yet.\nPair one from Gossip's menu → Settings.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(rows) { row in rowView(row) }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 420, height: 380)
    }

    @ViewBuilder
    private func rowView(_ row: MirrorRow) -> some View {
        HStack(spacing: 12) {
            Image(systemName: row.deviceType.symbolName).font(.title2).frame(width: 28)
                .foregroundStyle(MenuBarView.color(for: row.connectivity))
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).lineLimit(1)
                HStack(spacing: 6) {
                    Circle().fill(MenuBarView.color(for: row.connectivity)).frame(width: 7, height: 7)
                    Text(row.connectivity == .mesh
                         ? "Connected through another device — mirroring needs a direct connection"
                         : row.connectivity == .relayed
                         ? "Connected through the relay — mirroring needs the same network"
                         : MenuBarView.description(of: row.connectivity))
                    if let battery = row.battery {
                        Image(systemName: MenuBarView.batterySymbol(battery))
                        Text("\(battery.level)%")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            actionButton(row)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.12)))
    }

    @ViewBuilder
    private func actionButton(_ row: MirrorRow) -> some View {
        let isThisDevice = screenMirrorController.mirroringDeviceId == row.id
        switch (screenMirrorController.state, isThisDevice) {
        case (.idle, _):
            Button("Mirror") {
                screenMirrorController.start(deviceId: row.id, deviceName: row.name, transport: transportManager)
            }
            .disabled(!row.isConnected || !featureSettings.isEnabled(.screenMirroring))
        case (.starting, true):
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Starting…").font(.caption) }
        case (.mirroring, true):
            Button("Stop") { screenMirrorController.stop() }
        case (.starting, false), (.mirroring, false):
            Button("Mirror") {}.disabled(true)
        }
    }
}

/// Plain `NSWindow` hosting `DeviceMirroringView` (same pattern as `SettingsWindow`).
final class DeviceMirroringWindow: NSWindow {
    init(rootView: DeviceMirroringView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 380),
                   styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        title = "Device Mirroring"
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: rootView)
        center()
    }
}

/// Holds the single Device Mirroring window so repeated opens bring the same one forward.
final class DeviceMirroringWindowBox {
    private var window: DeviceMirroringWindow?

    func show(makeView: () -> DeviceMirroringView) {
        if window == nil { window = DeviceMirroringWindow(rootView: makeView()) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
