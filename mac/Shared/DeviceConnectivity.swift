import Foundation

/// How this device reaches a paired device right now — drives the green / blue / grey device icon.
enum Connectivity: Equatable {
    /// A live connection straight to that device.
    case direct
    /// Connected, but only through the relay (not on the same network): messages flow, same-network features do not.
    case relayed
    /// No direct connection, but it was heard from recently through another device (the mesh relays every
    /// broadcast, so its periodic updates still arrive).
    case mesh
    case none
}

enum DeviceConnectivity {
    /// How long after the last message from a device it still counts as reachable over the mesh. Devices
    /// broadcast something at least every 60s (`battery.update`, `dnd.update`, ...), so this tolerates two
    /// missed rounds.
    static let meshTTL: TimeInterval = 150

    /// Devices not directly connected that were heard from within `ttl`.
    static func meshReachable(lastHeard: [String: Date], directIds: Set<String>, selfId: String,
                              now: Date, ttl: TimeInterval = DeviceConnectivity.meshTTL) -> Set<String> {
        Set(lastHeard.filter { id, at in id != selfId && !directIds.contains(id) && now.timeIntervalSince(at) < ttl }.keys)
    }

    static func classify(_ deviceId: String, directIds: Set<String>, meshIds: Set<String>, relayedIds: Set<String> = []) -> Connectivity {
        if directIds.contains(deviceId) { return .direct }
        if relayedIds.contains(deviceId) { return .relayed }
        if meshIds.contains(deviceId) { return .mesh }
        return .none
    }
}
