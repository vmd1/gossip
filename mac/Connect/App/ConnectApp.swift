import SwiftUI
import AppKit
import UserNotifications
import Combine
import CryptoKit

@main
struct ConnectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var trustedDevicesStore = TrustedDevicesStore.shared
    @StateObject private var transportManager: TransportManager
    @StateObject private var pairingViewModel: PairingViewModel
    @StateObject private var screenMirrorController = ScreenMirrorController()
    @StateObject private var mediaControlManager: MediaControlManager
    @StateObject private var notificationMirrorManager: NotificationMirrorManager
    private let dndSyncManager: DNDSyncManager
    @StateObject private var clipboardSyncManager: ClipboardSyncManager
    private let rosterGossipManager: RosterGossipManager
    @StateObject private var bleProximityMonitor: BLEProximityMonitor
    @StateObject private var hotspotStateManager: HotspotStateManager
    private let lockOnLeaveManager: LockOnLeaveManager

    /// Holds the `connectionState` subscription driving `dndSyncManager.reportInitialSyncState()`
    /// (see `init()`). Must live somewhere with the app's own lifetime, not a SwiftUI view's —
    /// `MenuBarView`'s content (and any `.onChange` on it) isn't guaranteed to exist until the
    /// user opens the tray at least once, the same bug `transport.start()`/`onOpenURLs` already
    /// hit twice in this codebase. A `State` class box because `ConnectApp` itself is a struct.
    private final class SubscriptionBox { var cancellable: AnyCancellable? }
    private let subscriptions = SubscriptionBox()
    // TEMPORARY: retains the in-flight debug-hotspot-request client so it isn't
    // deallocated before its async GATT exchange completes — remove alongside the
    // debug URL hook itself once real UI testing supersedes it.
    private final class HotspotClientBox { var client: HotspotGattClient? }
    private let debugHotspotClientBox = HotspotClientBox()
    private let dndResyncSubscriptions = SubscriptionBox()
    private let fallbackDialSubscriptions = SubscriptionBox()
    private let rosterResyncSubscriptions = SubscriptionBox()

    /// Same rationale as `SubscriptionBox` above: `OnboardingWindow`/`PairingWindow` are
    /// local values with nothing else keeping them alive once `init()`/a button closure
    /// returns, unlike `MenuBarView`'s `@State private var pairingWindow`, which only
    /// exists once the menu-bar tray has actually been opened — exactly the timing bug
    /// this class's other boxes were added to avoid (see `transport.start()`'s doc
    /// comment). Held at `ConnectApp` scope instead so first-run onboarding (and pairing
    /// launched from inside it) survives being shown before the tray is ever opened.
    private final class WindowBox { var window: NSWindow? }
    private let onboardingWindowBox = WindowBox()
    private let onboardingPairingWindowBox = WindowBox()

    init() {
        let transport = TransportManager()
        _transportManager = StateObject(wrappedValue: transport)
        let pairingViewModel = PairingViewModel(transportManager: transport)
        _pairingViewModel = StateObject(wrappedValue: pairingViewModel)
        _mediaControlManager = StateObject(wrappedValue: MediaControlManager(transportManager: transport))
        let notificationMirror = NotificationMirrorManager(transportManager: transport)
        _notificationMirrorManager = StateObject(wrappedValue: notificationMirror)
        UNUserNotificationCenter.current().delegate = notificationMirror
        dndSyncManager = DNDSyncManager(transportManager: transport)
        _clipboardSyncManager = StateObject(wrappedValue: ClipboardSyncManager(transportManager: transport))
        rosterGossipManager = RosterGossipManager(transportManager: transport)
        let bleMonitor = BLEProximityMonitor(trustedDevicesStore: TrustedDevicesStore.shared)
        _bleProximityMonitor = StateObject(wrappedValue: bleMonitor)
        _hotspotStateManager = StateObject(wrappedValue: HotspotStateManager(transportManager: transport))
        lockOnLeaveManager = LockOnLeaveManager(
            transportManager: transport,
            trustedDevicesStore: TrustedDevicesStore.shared,
            bleProximityMonitor: bleMonitor
        )

        // Must run unconditionally at process launch, not from the menu-bar
        // dropdown's `.onAppear` (the previous location): for a
        // `.menuBarExtraStyle(.window)` scene, that content only composes —
        // and `.onAppear` only fires — the first time the user actually opens
        // the tray. Auto-reconnecting to an already-trusted peer (the entire
        // point of a background sync app) was silently never happening after
        // a fresh launch until the user happened to click the menu-bar icon.
        transport.start()
        notificationMirror.requestAuthorizationIfNeeded()

        // First-run onboarding (see `HANDOFF_ONBOARDING_AND_POLISH.md` Phase 2). Same
        // "must not depend on the menu-bar tray ever being opened" reasoning as
        // `transport.start()` above — shown unconditionally here, not from
        // `MenuBarView.onAppear`, and held in `onboardingWindowBox` (see its doc
        // comment) so nothing releases it before the user interacts with it.
        if !OnboardingPreferences.isCompleted {
            let onboarding = OnboardingWindow(
                onPairNewDevice: { [pairingViewModel, onboardingPairingWindowBox] in
                    pairingViewModel.startPairing()
                    let window = PairingWindow(pairingViewModel: pairingViewModel)
                    onboardingPairingWindowBox.window = window
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                },
                onOpenDNDSetup: { [onboardingPairingWindowBox] in
                    let window = DNDSetupWindow()
                    onboardingPairingWindowBox.window = window
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                },
                notificationAuthorizationStatus: { [notificationMirror] in
                    notificationMirror.authorizationStatus
                },
                onOpenNotificationSettings: {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                        NSWorkspace.shared.open(url)
                    }
                }
            )
            onboardingWindowBox.window = onboarding
            onboarding.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        // Same reasoning as `transport.start()` above, and the same bug: this was
        // previously wired from `MenuBarView`'s `.onAppear`, so `connect://` URLs
        // (from the Shortcuts "When Focus is turned on/off" automations) were
        // silently dropped by `AppDelegate.application(_:open:)`'s `onOpenURLs?(urls)`
        // no-op on `nil` until the user opened the menu bar tray at least once after
        // launch.
        appDelegate.onOpenURLs = { [dndSyncManager, bleMonitor, debugHotspotClientBox] urls in
            for url in urls {
                if url.host == "debug-hotspot-request" {
                    // TEMPORARY debug hook to live-test HotspotGattClient end to end
                    // before there's a scriptable UI path — remove once this is
                    // exercised through the real "Request Hotspot" menu bar button
                    // instead.
                    let phones = TrustedDevicesStore.shared.devices.filter { $0.deviceType == .androidPhone }
                    BLEProximityMonitor.debugLog("debug-hotspot-request: trusted phones=\(phones.map { $0.deviceId }) peripheralIds=\(bleMonitor.peripheralIdentifierByDeviceId) nearby=\(bleMonitor.nearbyDeviceIds)")
                    guard let deviceId = phones.first?.deviceId,
                          let peripheralId = bleMonitor.peripheralIdentifierByDeviceId[deviceId] else {
                        BLEProximityMonitor.debugLog("debug-hotspot-request: no nearby trusted phone found")
                        continue
                    }
                    BLEProximityMonitor.debugLog("debug-hotspot-request: requesting from \(deviceId)")
                    let client = HotspotGattClient()
                    debugHotspotClientBox.client = client
                    client.requestToggle(providerId: deviceId, peripheralIdentifier: peripheralId, enable: true) { result in
                        BLEProximityMonitor.debugLog("debug-hotspot-request result: \(result)")
                        debugHotspotClientBox.client = nil
                    }
                } else {
                    dndSyncManager.handleIncomingURL(url)
                }
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

        // Mac normally only ever *discovers* peers (Bonjour browse) — it has no equivalent
        // to Android's fallback dial loop, so a Mac that isn't on the paired phone's LAN/mDNS
        // domain (e.g. bridged only by a Tailscale tunnel) has no path back to CONNECTED at
        // all. Mirrors Android's `SyncForegroundService.runFallbackDialLoop`: while not
        // connected/handshaking, and only if the user configured a fallback address for a
        // trusted device (Trusted Devices list in the menu), periodically dial it directly on
        // the fixed port, bypassing discovery. See `TrustedDevice.fallbackHost` and
        // `docs/wire-protocol.md`.
        // Dials *every* trusted device with a configured fallback host that
        // isn't already connected — not just the first one found while fully
        // idle. With a mesh, this Mac may already be connected to some
        // trusted devices while still needing to fallback-dial others.
        let trustedDevices = trustedDevicesStore
        fallbackDialSubscriptions.cancellable = Timer.publish(every: 15, on: .main, in: .common)
            .autoconnect()
            .sink { [transport, trustedDevices] _ in
                for target in trustedDevices.allDevices() {
                    guard let host = target.fallbackHost, !host.isEmpty else { continue }
                    guard !transport.connectedDeviceIds.contains(target.deviceId) else { continue }
                    guard let keyData = Data(base64Encoded: target.publicKeyBase64),
                          let staticKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyData)
                    else { continue }
                    transport.connect(toFallbackHost: host, remoteStaticKey: staticKey, deviceId: target.deviceId)
                }
            }

        // Self-healing backstop for roster gossip, on top of the event-driven paths
        // (a fresh connection, or a brand-new pairing): periodically re-broadcasts the
        // full local roster to every connected peer. Mirrors the DND resync loop above
        // — safe to call repeatedly, since re-adding an already-trusted device is a
        // no-op (see `RosterGossipManager.handleRosterUpdate`).
        let roster = rosterGossipManager
        rosterResyncSubscriptions.cancellable = Timer.publish(every: 300, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                roster.periodicResync()
            }
    }

    var body: some Scene {
        MenuBarExtra("Connect", systemImage: "laptopcomputer.and.iphone") {
            MenuBarView(
                transportManager: transportManager,
                pairingViewModel: pairingViewModel,
                trustedDevicesStore: trustedDevicesStore,
                screenMirrorController: screenMirrorController,
                mediaControlManager: mediaControlManager,
                notificationMirrorManager: notificationMirrorManager,
                rosterGossipManager: rosterGossipManager,
                bleProximityMonitor: bleProximityMonitor,
                hotspotStateManager: hotspotStateManager
            )
        }
        .menuBarExtraStyle(.window)
    }
}
