import SwiftUI

@main
struct ConnectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var trustedDevicesStore = TrustedDevicesStore.shared
    @StateObject private var transportManager: TransportManager
    @StateObject private var pairingViewModel: PairingViewModel
    @StateObject private var clipboardSyncManager: ClipboardSyncManager

    init() {
        let transport = TransportManager()
        _transportManager = StateObject(wrappedValue: transport)
        _pairingViewModel = StateObject(wrappedValue: PairingViewModel(transportManager: transport))
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
