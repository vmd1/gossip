import Foundation

/// One line of the Device Mirroring window.
struct MirrorRow: Equatable, Identifiable {
    let id: String
    let name: String
    let deviceType: DeviceType
    let connectivity: Connectivity
    /// Mirroring streams straight from the phone to this Mac over the local network, so it needs a direct connection.
    var isConnected: Bool { connectivity == .direct }
    let battery: BatteryState?
}

enum DeviceMirroringRows {
    /// The devices that can be mirrored — Android phones and tablets (a Mac has nothing to stream) —
    /// connected ones first, then by name.
    static func rows(devices: [TrustedDevice], connectedIds: Set<String>, meshIds: Set<String> = [], batteries: [String: BatteryState]) -> [MirrorRow] {
        devices
            .filter { $0.deviceType != .mac }
            .map { MirrorRow(id: $0.deviceId, name: $0.deviceName, deviceType: $0.deviceType,
                             connectivity: DeviceConnectivity.classify($0.deviceId, directIds: connectedIds, meshIds: meshIds),
                             battery: batteries[$0.deviceId]) }
            .sorted {
                let a = $0.connectivity.sortRank, b = $1.connectivity.sortRank
                if a != b { return a < b }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }
}

private extension Connectivity {
    var sortRank: Int { switch self { case .direct: return 0; case .mesh: return 1; case .none: return 2 } }
}
