import Foundation

extension TransportManager: ControlMesh {
    func isDirectlyConnected(_ deviceId: String) -> Bool { connectedDeviceIds.contains(deviceId) }

    func host(for deviceId: String) -> String? { hostWithZone(for: deviceId) }

    /// `control.*` messages carry key material, so they are targeted (`ttl: 0`, never relayed) and refused
    /// outright unless `deviceId` is a direct connection — the mesh would otherwise flood them through
    /// intermediate devices.
    func sendControl(type: String, to deviceId: String, payload: [String: JSONValue]) {
        guard isDirectlyConnected(deviceId) else { return }
        let envelope = Envelope(
            type: type, senderId: IdentityKeyStore.shared.deviceId,
            recipientId: deviceId, ttl: 0, payload: .object(payload)
        )
        try? send(envelope: envelope)
    }
}
