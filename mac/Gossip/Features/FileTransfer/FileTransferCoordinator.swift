import Foundation
import AppKit
import Combine

/// The Mac side of file transfer that is not the protocol: the accept prompt, the Downloads folder, "Send File…" and the
/// progress the menu shows. Owns the `FileTransferManager` and connects it to the transport.
final class FileTransferCoordinator: ObservableObject {
    /// The latest line to show in the menu (progress or the last outcome); nil when nothing has happened.
    @Published private(set) var status: String?

    private(set) var manager: FileTransferManager!
    private weak var transport: TransportManager?
    private var cancellables = Set<AnyCancellable>()
    private var alerts: [String: NSAlert] = [:]
    private var knownConnected: Set<String> = []

    init(transport: TransportManager, trustedDevices: TrustedDevicesStore = .shared, identity: IdentityKeyStore = .shared) {
        self.transport = transport
        let partDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gossip", isDirectory: true).appendingPathComponent("incoming", isDirectory: true)
        manager = FileTransferManager(
            selfId: identity.deviceId,
            partDir: partDir,
            sendEnvelope: { [weak transport] envelope, raw in
                guard let transport else { throw TransportManager.SendError.notConnected }
                if let raw { try transport.send(envelope, withRawFollowup: raw) } else { try transport.send(envelope: envelope) }
            },
            isConnected: { [weak transport] id in transport?.connectedDeviceIds.contains(id) ?? false },
            pendingOutboundBytes: { [weak transport] in transport?.pendingOutboundBytes() ?? 0 },
            peerName: { id in trustedDevices.devices.first { $0.deviceId == id }?.deviceName ?? "A device" },
            saveToDownloads: { part, name in Self.saveToDownloads(part, name) },
            freeSpace: { Self.freeSpace() },
            onOffer: { [weak self] offer in DispatchQueue.main.async { self?.prompt(offer) } },
            onChanged: { [weak self] info in DispatchQueue.main.async { self?.show(info) } }
        )
        transport.router.register(prefix: "file.") { [weak self] envelope in
            if envelope.type != "file.chunk" { self?.manager.handle(envelope) }
        }
        transport.setRawHandler(for: "file.chunk") { [weak self] envelope, raw in self?.manager.handleChunk(envelope, raw: raw) }
        transport.$connectedDeviceIds.receive(on: DispatchQueue.main).sink { [weak self] now in
            guard let self else { return }
            for id in now.subtracting(self.knownConnected) { self.manager.peerConnected(id) }
            self.knownConnected = now
        }.store(in: &cancellables)
    }

    // MARK: sending

    /// "Send File…" on a device row.
    func chooseAndSend(to device: TrustedDevice) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose files to send to \(device.deviceName)"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { send(panel.urls, to: device) }
    }

    func send(_ urls: [URL], to device: TrustedDevice) {
        for url in urls where url.isFileURL {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do { _ = try self?.manager.sendFile(to: device.deviceId, url: url) }
                catch { DispatchQueue.main.async { self?.status = "Could not send \(url.lastPathComponent): \(error.localizedDescription)" } }
            }
        }
    }

    // MARK: receiving

    private func prompt(_ offer: IncomingFileOffer) {
        let alert = NSAlert()
        alert.messageText = "\(offer.peerName) wants to send you a file"
        alert.informativeText = "\(offer.name)\n\(ByteCountFormatter.string(fromByteCount: offer.size, countStyle: .file)) · saved to your Downloads folder"
        alert.addButton(withTitle: "Accept")
        let decline = alert.addButton(withTitle: "Decline")
        decline.keyEquivalent = "\u{1b}"
        alerts[offer.transferId] = alert
        NSApp.activate(ignoringOtherApps: true)
        // Declining is the default: the manager declines on its own after two minutes, and a closed alert is a decline too.
        let response = alert.runModal()
        alerts[offer.transferId] = nil
        manager.respond(offer.transferId, accept: response == .alertFirstButtonReturn)
    }

    private func show(_ info: FileTransferInfo) {
        switch info.state {
        case "done": status = info.outgoing ? "Sent \(info.name)" : "Received \(info.name)"
        case "failed", "rejected", "cancelled": status = "\(info.name): \(info.state)"
        default:
            let pct = info.size == 0 ? 100 : Int(info.bytes * 100 / max(info.size, 1))
            status = "\(info.outgoing ? "Sending" : "Receiving") \(info.name): \(pct)%"
        }
    }

    /// Moves a verified file into ~/Downloads under a name that is not taken, returning the final name.
    static func saveToDownloads(_ part: URL, _ name: String) -> String? {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return nil }
        let final = FileTransferRules.uniqueName(name) { FileManager.default.fileExists(atPath: downloads.appendingPathComponent($0).path) }
        do { try FileManager.default.moveItem(at: part, to: downloads.appendingPathComponent(final)); return final } catch { return nil }
    }

    static func freeSpace() -> Int64 {
        let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? Int64.max
    }
}
