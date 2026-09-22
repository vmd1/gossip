import SwiftUI
import UserNotifications

@main
struct ConnectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var trustedDevicesStore = TrustedDevicesStore.shared
    @StateObject private var transportManager: TransportManager
    @StateObject private var pairingViewModel: PairingViewModel
    @StateObject private var screenMirrorController = ScreenMirrorController()
    @StateObject private var fileTransferManager: FileTransferManager
    @StateObject private var mediaControlManager: MediaControlManager
    private let notificationMirrorManager: NotificationMirrorManager
    private let dndSyncManager: DNDSyncManager
    @StateObject private var clipboardSyncManager: ClipboardSyncManager

    init() {
        let transport = TransportManager()
        _transportManager = StateObject(wrappedValue: transport)
        _pairingViewModel = StateObject(wrappedValue: PairingViewModel(transportManager: transport))
        _fileTransferManager = StateObject(wrappedValue: FileTransferManager(transportManager: transport))
        _mediaControlManager = StateObject(wrappedValue: MediaControlManager(transportManager: transport))
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
                trustedDevicesStore: trustedDevicesStore,
                screenMirrorController: screenMirrorController,
                fileTransferManager: fileTransferManager,
                mediaControlManager: mediaControlManager
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
