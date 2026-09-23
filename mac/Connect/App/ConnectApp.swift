import SwiftUI
import UserNotifications
import Combine

@main
struct ConnectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var trustedDevicesStore = TrustedDevicesStore.shared
    @StateObject private var transportManager: TransportManager
    @StateObject private var pairingViewModel: PairingViewModel
    @StateObject private var screenMirrorController = ScreenMirrorController()
    @StateObject private var fileTransferManager: FileTransferManager
    @StateObject private var mediaControlManager: MediaControlManager
    @StateObject private var notificationMirrorManager: NotificationMirrorManager
    private let dndSyncManager: DNDSyncManager
    @StateObject private var clipboardSyncManager: ClipboardSyncManager

    /// Holds the `connectionState` subscription driving `dndSyncManager.reportInitialSyncState()`
    /// (see `init()`). Must live somewhere with the app's own lifetime, not a SwiftUI view's —
    /// `MenuBarView`'s content (and any `.onChange` on it) isn't guaranteed to exist until the
    /// user opens the tray at least once, the same bug `transport.start()`/`onOpenURLs` already
    /// hit twice in this codebase. A `State` class box because `ConnectApp` itself is a struct.
    private final class SubscriptionBox { var cancellable: AnyCancellable? }
    private let subscriptions = SubscriptionBox()
    private let dndResyncSubscriptions = SubscriptionBox()

    init() {
        let transport = TransportManager()
        _transportManager = StateObject(wrappedValue: transport)
        _pairingViewModel = StateObject(wrappedValue: PairingViewModel(transportManager: transport))
        _fileTransferManager = StateObject(wrappedValue: FileTransferManager(transportManager: transport))
        _mediaControlManager = StateObject(wrappedValue: MediaControlManager(transportManager: transport))
        let notificationMirror = NotificationMirrorManager(transportManager: transport)
        _notificationMirrorManager = StateObject(wrappedValue: notificationMirror)
        UNUserNotificationCenter.current().delegate = notificationMirror
        dndSyncManager = DNDSyncManager(transportManager: transport)
        _clipboardSyncManager = StateObject(wrappedValue: ClipboardSyncManager(transportManager: transport))

        // Must run unconditionally at process launch, not from the menu-bar
        // dropdown's `.onAppear` (the previous location): for a
        // `.menuBarExtraStyle(.window)` scene, that content only composes —
        // and `.onAppear` only fires — the first time the user actually opens
        // the tray. Auto-reconnecting to an already-trusted peer (the entire
        // point of a background sync app) was silently never happening after
        // a fresh launch until the user happened to click the menu-bar icon.
        transport.start()
        notificationMirror.requestAuthorizationIfNeeded()

        // Same reasoning as `transport.start()` above, and the same bug: this was
        // previously wired from `MenuBarView`'s `.onAppear`, so `connect://` URLs
        // (from the Shortcuts "When Focus is turned on/off" automations) were
        // silently dropped by `AppDelegate.application(_:open:)`'s `onOpenURLs?(urls)`
        // no-op on `nil` until the user opened the menu bar tray at least once after
        // launch.
        appDelegate.onOpenURLs = { [dndSyncManager] urls in
            for url in urls {
                dndSyncManager.handleIncomingURL(url)
            }
        }

        // Same reasoning as `transport.start()`/`onOpenURLs` above: must not depend on
        // `MenuBarView`'s content ever having appeared. In particular
        // `reportInitialSyncState()` reconciling a pre-existing DND mismatch needs to fire
        // on *every* connect, including the very first one after a fresh launch — which is
        // exactly the case most likely to happen before the user has ever opened the tray.
        let clipboard = clipboardSyncManager
        subscriptions.cancellable = transport.$connectionState.sink { [dndSyncManager, clipboard, notificationMirror] state in
            if case .connected = state {
                clipboard.start()
                notificationMirror.refreshAuthorizationStatus()
                dndSyncManager.reportInitialSyncState()
            } else {
                clipboard.stop()
            }
        }

        // Self-healing backstop for DND sync, on top of the event-driven paths above
        // (a local change, or a fresh connect): periodically re-send this Mac's current
        // state as another `isInitialSync` OR-merge report while connected. Event-driven
        // sync alone has no recovery if a single message is ever dropped, sent while
        // transiently disconnected, or missed by a race — the two devices then stay
        // silently mismatched indefinitely, which is exactly the failure mode several
        // bugs in this DND feature turned out to be. Reusing the OR-merge (rather than a
        // plain mirror) keeps this safe to call repeatedly: it only acts on a genuine
        // disagreement, so healthy periods are no-ops. Matches Android's
        // `SyncForegroundService.runDndResyncLoop`.
        dndResyncSubscriptions.cancellable = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [dndSyncManager, transport] _ in
                if case .connected = transport.connectionState {
                    dndSyncManager.reportInitialSyncState()
                }
            }
    }

    var body: some Scene {
        MenuBarExtra("Connect", systemImage: "laptopcomputer.and.iphone") {
            MenuBarView(
                transportManager: transportManager,
                pairingViewModel: pairingViewModel,
                trustedDevicesStore: trustedDevicesStore,
                screenMirrorController: screenMirrorController,
                fileTransferManager: fileTransferManager,
                mediaControlManager: mediaControlManager,
                notificationMirrorManager: notificationMirrorManager
            )
        }
        .menuBarExtraStyle(.window)
    }
}
