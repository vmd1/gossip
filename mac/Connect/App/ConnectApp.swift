import SwiftUI
import UserNotifications

@main
struct ConnectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var trustedDevicesStore = TrustedDevicesStore.shared
    @StateObject private var transportManager: TransportManager
    @StateObject private var pairingViewModel: PairingViewModel
    private let notificationMirrorManager: NotificationMirrorManager
    private let dndSyncManager: DNDSyncManager
    @StateObject private var clipboardSyncManager: ClipboardSyncManager

    init() {
        let transport = TransportManager()
        _transportManager = StateObject(wrappedValue: transport)
        _pairingViewModel = StateObject(wrappedValue: PairingViewModel(transportManager: transport))
        notificationMirrorManager = NotificationMirrorManager(transportManager: transport)
        UNUserNotificationCenter.current().delegate = notificationMirrorManager
        dndSyncManager = DNDSyncManager(transportManager: transport)
        _clipboardSyncManager = StateObject(wrappedValue: ClipboardSyncManager(transportManager: transport))
    }

    var body: some Scene {
        MenuBarExtra("Connect", systemImage: "laptopcomputer.and.iphone") {
            MenuBarView(
                transportManager: transportManager,
                pairingViewModel: pairingViewModel,
                trustedDevicesStore: trustedDevicesStore
            )
            .onAppear {
                transportManager.start()
                notificationMirrorManager.requestAuthorizationIfNeeded()
                appDelegate.onOpenURLs = { urls in
                    for url in urls {
                        dndSyncManager.handleIncomingURL(url)
                    }
                }
            }
            .onChange(of: transportManager.connectionState) { _, newState in
                if case .connected = newState {
                    clipboardSyncManager.start()
                } else {
                    clipboardSyncManager.stop()
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
