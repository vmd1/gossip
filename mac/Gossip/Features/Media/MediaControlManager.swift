import Foundation
import Combine

/// `type` values this unit registers in `schema/message-types.md`.
enum MediaMessageType {
    static let nowPlaying = "media.nowplaying"
    static let command = "media.command"
}

/// Playback commands understood by the phone's `media.command` handler.
enum MediaCommandAction: String {
    case play
    case pause
    case next
    case previous
}

/// Now-playing state mirrored from the phone's active media session, as published
/// by a `media.nowplaying` envelope. See `schema/message-types.md` for the wire shape.
struct NowPlayingState: Equatable {
    var title: String
    var artist: String
    var artworkData: Data?
    var isPlaying: Bool
    var positionMs: Int
    var durationMs: Int
    var packageName: String
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

    init(transportManager: TransportManager, identity: IdentityKeyStore = .shared) {
        self.transportManager = transportManager
        self.identity = identity
        transportManager.router.register(prefix: MediaMessageType.nowPlaying) { [weak self] envelope in
            guard let state = Self.parseNowPlaying(envelope.payload) else { return }
            DispatchQueue.main.async {
                self?.nowPlayingByDevice[envelope.senderId] = state
                self?.mostRecentDeviceId = envelope.senderId
            }
        }
    }

    /// The now-playing state currently shown/controlled by the menu bar UI.
    var nowPlaying: NowPlayingState? {
        guard let deviceId = effectiveSelectedDeviceId else { return nil }
        return nowPlayingByDevice[deviceId]
    }

    private var effectiveSelectedDeviceId: String? {
        if let selectedDeviceId, nowPlayingByDevice[selectedDeviceId] != nil {
            return selectedDeviceId
        }
        return mostRecentDeviceId
    }

    // MARK: - Parsing (pure, unit-testable without a live transport)

    static func parseNowPlaying(_ payload: JSONValue) -> NowPlayingState? {
        guard let title = payload["title"]?.stringValue,
              let artist = payload["artist"]?.stringValue else { return nil }

        let artBase64 = payload["artBase64"]?.stringValue
        let artworkData = artBase64.flatMap { Data(base64Encoded: $0) }
        let isPlaying = payload["isPlaying"].flatMap(Self.boolValue) ?? false
        let positionMs = payload["positionMs"].flatMap(Self.intValue) ?? 0
        let durationMs = payload["durationMs"].flatMap(Self.intValue) ?? 0
        let packageName = payload["packageName"]?.stringValue ?? ""

        return NowPlayingState(
            title: title,
            artist: artist,
            artworkData: artworkData,
            isPlaying: isPlaying,
            positionMs: positionMs,
            durationMs: durationMs,
            packageName: packageName
        )
    }

    /// `commandId` uniquely identifies this command *instance* (a fresh UUID per call,
    /// not per action) so the Android receiver can drop an exact duplicate delivery
    /// (retry, relay race, dedupe-cache eviction) without skipping/rewinding twice —
    /// see `MediaControlBridge.handleCommand` (Android).
    static func commandPayload(action: MediaCommandAction, seekMs: Int?, commandId: String = UUID().uuidString) -> JSONValue {
        var fields: [String: JSONValue] = ["action": .string(action.rawValue), "commandId": .string(commandId)]
        if let seekMs {
            fields["seekMs"] = .number(Double(seekMs))
        }
        return .object(fields)
    }

    private static func boolValue(_ value: JSONValue) -> Bool? {
        if case .bool(let b) = value { return b }
        return nil
    }

    private static func intValue(_ value: JSONValue) -> Int? {
        if case .number(let n) = value { return Int(n) }
        return nil
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
