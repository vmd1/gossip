import Foundation
import Combine
import GossipCoreKit

/// `type` values this unit registers in `schema/message-types.md`.
enum MediaMessageType {
    /// The synchronised state slot a phone keeps its now-playing state in.
    static let nowPlayingSlot = "media.nowplaying"
    static let command = "media.command"
}

/// Playback commands understood by the phone's `media.command` handler.
enum MediaCommandAction: String {
    case play
    case pause
    case next
    case previous
}

/// Now-playing state mirrored from the phone's active media session, as published in the `media.nowplaying` state slot.
/// See `schema/message-types.md` for the shape.
struct NowPlayingState: Equatable {
    var title: String
    var artist: String
    var artworkData: Data?
    var isPlaying: Bool
    var positionMs: Int
    var durationMs: Int
    var packageName: String

    init(title: String, artist: String, artworkData: Data?, isPlaying: Bool, positionMs: Int, durationMs: Int, packageName: String) {
        self.title = title; self.artist = artist; self.artworkData = artworkData; self.isPlaying = isPlaying
        self.positionMs = positionMs; self.durationMs = durationMs; self.packageName = packageName
    }

    init(_ core: GossipCoreKit.NowPlaying) {
        self.init(title: core.title, artist: core.artist, artworkData: core.artwork, isPlaying: core.isPlaying,
                  positionMs: Int(core.positionMs), durationMs: Int(core.durationMs), packageName: core.packageName)
    }
}

/// Registers a `MessageRouter` handler for `media.nowplaying` envelopes — broadcast by
/// every Android device in the mesh, not just a single tracked phone — and exposes each
/// sender's latest state to SwiftUI via `@Published`, keyed by `deviceId`; sends
/// `media.command` envelopes back over `TransportManager`, targeted at whichever
/// device's session is currently selected/shown, to control playback there specifically
/// (broadcasting a command would otherwise hit every phone's session at once).
final class MediaControlManager: ObservableObject {
    @Published private(set) var nowPlayingByDevice: [String: NowPlayingState] = [:]

    /// The user's explicit device selection, when more than one device is reporting a
    /// session. `nil` (the common single-phone case, and the default before any
    /// explicit pick) falls back to whichever device most recently reported.
    @Published var selectedDeviceId: String?

    /// Device ID of whichever entry in `nowPlayingByDevice` was most recently updated —
    /// the default when `selectedDeviceId` is unset or no longer present.
    private var mostRecentDeviceId: String?

    private weak var transportManager: TransportManager?
    private let identity: IdentityKeyStore

    private var cancellables = Set<AnyCancellable>()
    private let logic = GossipCoreKit.MediaController()

    init(transportManager: TransportManager, identity: IdentityKeyStore = .shared) {
        self.transportManager = transportManager
        self.identity = identity
        // Now-playing is a synchronised state slot (`media.nowplaying`, see `docs/plans/state-sync.md`): the core keeps it
        // correct across reconnects and drops it when the phone clears it, so there is no resync or expiry logic here.
        transportManager.addOnStateChanged { [weak self] change in
            guard change.slot == MediaMessageType.nowPlayingSlot else { return }
            self?.apply(deviceId: change.deviceId, valueJSON: change.valueJSON)
        }
        // A phone that is no longer reachable stops showing its card; the card comes back with the phone.
        // `meshReachableDeviceIds` leaves out phones that are connected directly or through the relay, so those sets count too.
        Publishers.Merge3(transportManager.$meshReachableDeviceIds.map { _ in () }, transportManager.$connectedDeviceIds.map { _ in () },
                          transportManager.$relayedDeviceIds.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    private func apply(deviceId: String, valueJSON: String?) {
        // The state, its parsing and the "which device is current" rule are the core's `MediaController`
        // (`desktop/core/src/features/media.rs`), shared with every platform.
        if let valueJSON, (try? logic.onNowPlaying(sender: deviceId, payloadJson: valueJSON)) != nil,
           let state = logic.stateOf(device: deviceId) {
            nowPlayingByDevice[deviceId] = NowPlayingState(state)
            mostRecentDeviceId = deviceId
        } else {
            // Cleared: the phone has no media session any more.
            logic.forget(sender: deviceId)
            nowPlayingByDevice.removeValue(forKey: deviceId)
            if mostRecentDeviceId == deviceId { mostRecentDeviceId = nowPlayingByDevice.keys.sorted().first }
        }
    }

    /// Devices whose card is shown: one that reported and is currently reachable.
    static func shownDevices(reported: Set<String>, reachable: Set<String>) -> Set<String> {
        reported.intersection(reachable)
    }

    private var shown: Set<String> {
        Self.shownDevices(reported: Set(nowPlayingByDevice.keys), reachable: transportManager.map { $0.meshReachableDeviceIds.union($0.connectedDeviceIds).union($0.relayedDeviceIds) } ?? [])
    }

    /// The now-playing state currently shown/controlled by the menu bar UI.
    var nowPlaying: NowPlayingState? {
        guard let deviceId = effectiveSelectedDeviceId, shown.contains(deviceId) else { return nil }
        return nowPlayingByDevice[deviceId]
    }

    private var effectiveSelectedDeviceId: String? {
        if let selectedDeviceId, shown.contains(selectedDeviceId) {
            return selectedDeviceId
        }
        if let mostRecentDeviceId, shown.contains(mostRecentDeviceId) { return mostRecentDeviceId }
        return shown.sorted().first
    }

    // MARK: - Parsing (pure, unit-testable without a live transport)

    /// Parses one `media.nowplaying` slot value (validated by the core).
    static func parseNowPlaying(_ payload: JSONValue) -> NowPlayingState? {
        guard let json = try? JSONEncoder().encode(payload) else { return nil }
        let controller = GossipCoreKit.MediaController()
        guard (try? controller.onNowPlaying(sender: "parse", payloadJson: String(decoding: json, as: UTF8.self))) != nil,
              let state = controller.stateOf(device: "parse") else { return nil }
        return NowPlayingState(state)
    }

    /// `commandId` uniquely identifies this command *instance* (a fresh UUID per call, not per action) so the Android receiver
    /// can drop an exact duplicate delivery without skipping/rewinding twice (the receiver is the core's `CommandGuard`).
    static func commandPayload(action: MediaCommandAction, seekMs: Int?, commandId: String = UUID().uuidString) -> JSONValue {
        let core: GossipCoreKit.MediaAction
        switch action {
        case .play: core = .play
        case .pause: core = .pause
        case .next: core = .next
        case .previous: core = .previous
        }
        let json = GossipCoreKit.mediaCommandPayload(action: core, seekMs: seekMs.map(Int64.init), commandId: commandId)
        return (try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))) ?? .object([:])
    }

    // MARK: - Sending commands

    func sendCommand(_ action: MediaCommandAction, seekMs: Int? = nil) {
        guard let transportManager, let deviceId = effectiveSelectedDeviceId else { return }
        let envelope = Envelope(
            type: MediaMessageType.command,
            senderId: identity.deviceId,
            recipientId: deviceId,
            payload: Self.commandPayload(action: action, seekMs: seekMs)
        )
        try? transportManager.send(envelope: envelope)
    }

    func play() { sendCommand(.play) }
    func pause() { sendCommand(.pause) }
    func next() { sendCommand(.next) }
    func previous() { sendCommand(.previous) }
}
