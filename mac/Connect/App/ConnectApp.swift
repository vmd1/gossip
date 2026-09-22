import SwiftUI
import UserNotifications

@main
struct ConnectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var trustedDevicesStore = TrustedDevicesStore.shared
    @StateObject private var transportManager: TransportManager
    @StateObject private var pairingViewModel: PairingViewModel
    private let notificationMirrorManager: NotificationMirrorManager

    init() {
        let transport = TransportManager()
        _transportManager = StateObject(wrappedValue: transport)
        _pairingViewModel = StateObject(wrappedValue: PairingViewModel(transportManager: transport))
        notificationMirrorManager = NotificationMirrorManager(transportManager: transport)
        UNUserNotificationCenter.current().delegate = notificationMirrorManager
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
            }
        }
        .menuBarExtraStyle(.window)
    }
}
