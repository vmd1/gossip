import SwiftUI

@main
struct ConnectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var trustedDevicesStore = TrustedDevicesStore.shared
    @StateObject private var transportManager: TransportManager
    @StateObject private var pairingViewModel: PairingViewModel
    private let dndSyncManager: DNDSyncManager

    init() {
        let transport = TransportManager()
        _transportManager = StateObject(wrappedValue: transport)
        _pairingViewModel = StateObject(wrappedValue: PairingViewModel(transportManager: transport))
        dndSyncManager = DNDSyncManager(transportManager: transport)
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
                appDelegate.onOpenURLs = { urls in
                    for url in urls {
                        dndSyncManager.handleIncomingURL(url)
                    }
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
