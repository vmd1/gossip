import SwiftUI
import AppKit

/// "Open App Window": pick an app on a phone or tablet and run it on a virtual display there, shown as its own Mac
/// window (`screen.start` with an `app`). One window at a time for now, because the phone runs a single capture session.
struct AppWindowPickerView: View {
    let device: TrustedDevice
    @ObservedObject var controller: ScreenMirrorController
    let transport: TransportManager
    var onOpened: () -> Void
    @State private var query = ""

    private var apps: [ScreenMirrorController.PhoneApp]? { controller.appsByDevice[device.deviceId] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Open an app from \(device.deviceName)").font(.headline)
            Text("Each app runs on its own virtual display, so the phone's screen stays free. Open several at once and resize their windows freely. Needs Shizuku on the phone.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Search apps", text: $query).textFieldStyle(.roundedBorder)
            if let error = controller.appsError[device.deviceId] {
                Text(error).foregroundStyle(.red)
            } else if let apps {
                let shown = query.isEmpty ? apps : apps.filter { $0.label.localizedCaseInsensitiveContains(query) }
                let icons = controller.iconsByDevice[device.deviceId] ?? [:]
                List(shown) { app in
                    Button {
                        controller.start(deviceId: device.deviceId, deviceName: device.deviceName, transport: transport, app: app)
                    } label: {
                        HStack(spacing: 10) {
                            Group {
                                if let icon = icons[app.package] {
                                    Image(nsImage: icon).resizable().interpolation(.high)
                                } else {
                                    RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.2))
                                }
                            }
                            .frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            Text(app.label)
                            Spacer()
                        }
                    }.buttonStyle(.plain)
                }
            } else {
                ProgressView("Loading apps…")
                Spacer()
            }
            if let error = controller.lastError { Text(error).foregroundStyle(.red).font(.caption) }
        }
        .padding(12)
        .frame(minWidth: 380, minHeight: 420)
        .onAppear { controller.requestApps(deviceId: device.deviceId, transport: transport) }
    }
}

enum AppWindowPicker {
    private static var window: NSWindow?

    static func show(device: TrustedDevice, controller: ScreenMirrorController, transport: TransportManager) {
        window?.close()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Open App Window"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: AppWindowPickerView(
            device: device, controller: controller, transport: transport, onOpened: { [weak w] in w?.close() }
        ))
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
