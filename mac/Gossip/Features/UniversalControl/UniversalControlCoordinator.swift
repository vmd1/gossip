import Foundation
import AppKit
import Combine
import CoreGraphics
import SwiftUI

/// App-lifetime glue for Universal Control: builds the manager, owns the event tap, keeps the permission
/// status fresh, and restores the cursor whenever the Mac sleeps, locks or quits. Not tied to any view
/// (same reasoning as `transport.start()` in `ConnectApp`).
final class UniversalControlCoordinator: ObservableObject {
    static let shared = UniversalControlCoordinator()

    @Published private(set) var accessibilityGranted = ControlEventTap.accessibilityGranted
    @Published private(set) var inputMonitoringGranted = ControlEventTap.inputMonitoringGranted
    @Published private(set) var tapRunning = false

    private(set) var manager: UniversalControlManager?
    private var transport: TransportManager?
    private let tap = ControlEventTap()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()
    private var layoutWindow: NSWindow?

    private init() {}

    func configure(transport: TransportManager, trustedDevices: TrustedDevicesStore, battery: BatterySyncManager) {
        guard manager == nil else { return }
        self.transport = transport
        self.trustedDevices = trustedDevices
        self.battery = battery
        let selfId = IdentityKeyStore.shared.deviceId
        let manager = UniversalControlManager(
            mesh: transport,
            makeSession: { [unowned transport] id in DeviceControlSession(deviceId: id, mesh: transport, selfId: selfId) },
            cursor: SystemCursorController(),
            macDisplays: Self.systemMacDisplays
        )
        self.manager = manager

        transport.router.register(prefix: "control.") { [weak manager] envelope in manager?.handleMesh(envelope) }

        transport.router.register(prefix: "display.info") { [weak manager] envelope in manager?.handleDisplayInfo(envelope) }

        tap.handler = { [weak manager] event in manager?.handle(event) ?? .pass }

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak manager] _ in
            manager?.displaysChanged()
        })
        // Put the pointer back before anything that would strand it.
        let returnHome: (Notification) -> Void = { [weak manager] _ in manager?.returnToMac() }
        observers.append(nc.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] n in
            returnHome(n); self?.tap.stop()
        })
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main, using: returnHome))
        }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main, using: returnHome))

        FeatureSettings.shared.$version.sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        transport.$connectedDeviceIds.sink { [weak manager] _ in DispatchQueue.main.async { manager?.reconcile() } }.store(in: &cancellables)

        manager.start()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    private(set) var trustedDevices: TrustedDevicesStore?
    private(set) var battery: BatterySyncManager?

    /// Re-reads permissions and starts/stops the event tap to match the feature toggle. Cheap; runs every 2 s.
    func refresh() {
        let ax = ControlEventTap.accessibilityGranted, im = ControlEventTap.inputMonitoringGranted
        if ax != accessibilityGranted { accessibilityGranted = ax }
        if im != inputMonitoringGranted { inputMonitoringGranted = im }
        let wantTap = FeatureSettings.shared.isEnabled(.universalControl) && ax
        if wantTap, !tap.isRunning { tap.start() }
        if !wantTap, tap.isRunning { manager?.returnToMac(); tap.stop() }
        if tapRunning != tap.isRunning { tapRunning = tap.isRunning }
    }

    // MARK: Displays

    /// Mac displays keyed by display UUID, in the global y-down point space `CGEvent` locations use.
    static func systemMacDisplays() -> [String: CGRect] {
        var result: [String: CGRect] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = CGDirectDisplayID(number.uint32Value)
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                  let string = CFUUIDCreateString(nil, uuid) as String? else { continue }
            result[string] = CGDisplayBounds(id)
        }
        return result
    }

    // MARK: Windows

    func showLayoutWindow() {
        guard let manager, let trustedDevices, let transport, let battery else { return }
        if layoutWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false
            )
            window.title = "Arrange Devices"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ControlLayoutView(
                manager: manager, trustedDevices: trustedDevices, transport: transport, battery: battery
            ))
            window.center()
            layoutWindow = window
        }
        layoutWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
