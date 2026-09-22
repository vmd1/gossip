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

/// Registers a `MessageRouter` handler for `media.nowplaying` envelopes from the phone
/// and exposes the latest state to SwiftUI via `@Published`; sends `media.command`
/// envelopes back over `TransportManager` to control playback on the phone.
final class MediaControlManager: ObservableObject {
    @Published private(set) var nowPlaying: NowPlayingState?

    private weak var transportManager: TransportManager?
    private let identity: IdentityKeyStore

    init(transportManager: TransportManager, identity: IdentityKeyStore = .shared) {
        self.transportManager = transportManager
        self.identity = identity
        transportManager.router.register(prefix: MediaMessageType.nowPlaying) { [weak self] envelope in
            guard let state = Self.parseNowPlaying(envelope.payload) else { return }
            DispatchQueue.main.async { self?.nowPlaying = state }
        }
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

    static func commandPayload(action: MediaCommandAction, seekMs: Int?) -> JSONValue {
        var fields: [String: JSONValue] = ["action": .string(action.rawValue)]
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
        guard let transportManager else { return }
        let envelope = Envelope(
            type: MediaMessageType.command,
            senderId: identity.deviceId,
            broadcast: true,
            payload: Self.commandPayload(action: action, seekMs: seekMs)
        )
        try? transportManager.send(envelope: envelope)
    }

    func play() { sendCommand(.play) }
    func pause() { sendCommand(.pause) }
    func next() { sendCommand(.next) }
    func previous() { sendCommand(.previous) }
}
