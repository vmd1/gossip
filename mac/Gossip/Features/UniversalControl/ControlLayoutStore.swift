import Foundation
import CoreGraphics

/// Persists the user's placements (and the last-known pixel size of each device) as JSON next to the other
/// Gossip state: `~/Library/Application Support/Connect/universal-control-layout.json`. Keyed by device id;
/// Mac displays are not stored — they come from the OS (by display UUID).
final class ControlLayoutStore {
    private struct File: Codable {
        var version = 1
        var devices: [String: ControlLayout.Placement] = [:]
        var sizes: [String: [Int]] = [:]
    }

    private let fileURL: URL
    private let queue = DispatchQueue(label: "dev.vmd1.gossip.control.layoutstore")

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            // Still "Connect" — see IdentityKeyStore.
            let dir = appSupport.appendingPathComponent("Connect", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("universal-control-layout.json")
        }
    }

    private func read() -> File {
        guard let data = try? Data(contentsOf: fileURL), let file = try? JSONDecoder().decode(File.self, from: data) else { return File() }
        return file
    }

    private func write(_ mutate: (inout File) -> Void) {
        queue.sync {
            var file = read()
            mutate(&file)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(file) { try? data.write(to: fileURL, options: .atomic) }
        }
    }

    func loadPlacements() -> [String: ControlLayout.Placement] { queue.sync { read().devices } }
    func savePlacements(_ placements: [String: ControlLayout.Placement]) { write { $0.devices = placements } }

    func loadSizes() -> [String: CGSize] {
        queue.sync { read().sizes.compactMapValues { $0.count == 2 ? CGSize(width: $0[0], height: $0[1]) : nil } }
    }
    func saveSizes(_ sizes: [String: CGSize]) {
        write { $0.sizes = sizes.mapValues { [Int($0.width), Int($0.height)] } }
    }
}
