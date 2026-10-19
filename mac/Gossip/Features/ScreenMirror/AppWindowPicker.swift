import SwiftUI
import AppKit

/// "Open App Window": a Launchpad-style grid of the apps on a phone or tablet. Click one to run it on a virtual display there,
/// shown as its own Mac window (`screen.start` with an `app`); several can be open at once.
struct AppWindowPickerView: View {
    let device: TrustedDevice
    @ObservedObject var controller: ScreenMirrorController
    let transport: TransportManager
    var onOpened: () -> Void
    @State private var query = ""
    @State private var hovered: String?

    private var apps: [ScreenMirrorController.PhoneApp]? { controller.appsByDevice[device.deviceId] }
    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 120), spacing: 14, alignment: .top)]

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            VStack(spacing: 14) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $query).textFieldStyle(.plain).font(.system(size: 14))
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .frame(maxWidth: 260)
                .padding(.top, 14)

                if let error = controller.appsError[device.deviceId] {
                    Spacer(); Text(error).foregroundStyle(.red); Spacer()
                } else if let apps {
                    let shown = query.isEmpty ? apps : apps.filter { $0.label.localizedCaseInsensitiveContains(query) }
                    let icons = controller.iconsByDevice[device.deviceId] ?? [:]
                    if shown.isEmpty {
                        Spacer(); Text("No Results").foregroundStyle(.secondary); Spacer()
                    } else {
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: 18) {
                                ForEach(shown) { app in tile(app, icon: icons[app.package]) }
                            }
                            .padding(.horizontal, 22).padding(.bottom, 18)
                        }
                    }
                } else {
                    Spacer(); ProgressView().controlSize(.regular); Spacer()
                }

                if let error = controller.lastError {
                    Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 16).padding(.bottom, 8)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 440)
        .onAppear { controller.requestApps(deviceId: device.deviceId, transport: transport) }
    }

    private func tile(_ app: ScreenMirrorController.PhoneApp, icon: NSImage?) -> some View {
        let open = controller.isAppOpen(app.package, on: device.deviceId)
        return Button {
            controller.start(deviceId: device.deviceId, deviceName: device.deviceName, transport: transport, app: app)
        } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let icon {
                            Image(nsImage: icon).resizable().interpolation(.high)
                        } else {
                            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.1))
                        }
                    }
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(hovered == app.id ? 0.35 : 0.2), radius: hovered == app.id ? 8 : 4, y: 2)
                    .opacity(app.disabled ? 0.45 : 1)
                    if open {
                        Circle().fill(Color.accentColor).frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2)).offset(x: 4, y: 4)
                    }
                }
                .scaleEffect(hovered == app.id ? 1.08 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovered)
                Text(app.label).font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.center)
                    .frame(maxWidth: 100, minHeight: 30, alignment: .top)
                if app.disabled { Text("Disabled").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            .padding(.vertical, 4).frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? app.id : (hovered == app.id ? nil : hovered) }
        .help(app.disabled ? "\(app.label) is disabled on the phone; opening it enables it first" : "Open \(app.label)")
    }
}

enum AppWindowPicker {
    private static var window: NSWindow?

    static func show(device: TrustedDevice, controller: ScreenMirrorController, transport: TransportManager) {
        window?.close()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 540),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Apps on \(device.deviceName)"
        w.titlebarAppearsTransparent = true
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
