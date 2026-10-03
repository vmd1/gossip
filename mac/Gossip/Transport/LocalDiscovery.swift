import Foundation
import Network

/// A discovered peer advertised over Bonjour.
struct DiscoveredPeer: Equatable {
    let deviceId: String
    let publicKeyFingerprint: String
    let endpoint: NWEndpoint
}

/// Advertises this Mac on the local network via Bonjour (`_gossip._tcp`) and
/// discovers other Connect devices doing the same. Does not itself open a data
/// connection — `TransportManager` uses the endpoints this class surfaces to
/// dial out with `NWConnection`.
final class LocalDiscovery {
    static let serviceType = "_gossip._tcp"

    /// Called on the main queue whenever the visible peer set changes.
    var onPeersChanged: (([DiscoveredPeer]) -> Void)?
    /// Called on the main queue when a remote peer connects to our advertised listener.
    var onIncomingConnection: ((NWConnection) -> Void)?

    private var listener: NWListener?
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "dev.vmd1.gossip.localdiscovery")

    private var discovered: [NWEndpoint: DiscoveredPeer] = [:]

    // MARK: - Advertising

    /// Starts advertising this device on the local network. `deviceId` and
    /// `publicKeyFingerprint` are published in the TXT record so peers can
    /// tell which physical device an advertisement belongs to before connecting.
    func startAdvertising(deviceId: String, deviceName: String, publicKeyFingerprint: String, port: NWEndpoint.Port? = nil) throws {
        let params = NWParameters.tcp
        params.includePeerToPeer = true

        let listener = try NWListener(using: params, on: port ?? .any)
        let txt = NWTXTRecord([
            "deviceId": deviceId,
            "fp": publicKeyFingerprint,
        ])
        listener.service = NWListener.Service(name: deviceName, type: Self.serviceType, txtRecord: txt)

        listener.newConnectionHandler = { [weak self] connection in
            DispatchQueue.main.async {
                self?.onIncomingConnection?(connection)
            }
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .failed(let error):
                gossipError("Gossip: Bonjour listener failed: \(error)")
            default:
                break
            }
        }

        listener.start(queue: queue)
        self.listener = listener
    }

    func stopAdvertising() {
        listener?.cancel()
        listener = nil
    }

    /// The TCP port this device ended up advertising on, once the listener is ready.
    var advertisedPort: NWEndpoint.Port? {
        listener?.port
    }

    // MARK: - Browsing

    func startBrowsing() {
        let params = NWParameters.tcp
        params.includePeerToPeer = true

        // `.bonjour(type:domain:)` never populates `result.metadata` (always
        // `.none`) — TXT records must be explicitly requested via
        // `.bonjourWithTXTRecord`, without which discovered peers' deviceId/fp
        // TXT entries never parse and every browse result is silently
        // discarded. See https://developer.apple.com/forums/thread/656570.
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handleResultsChanged(results)
        }
        browser.stateUpdateHandler = { state in
            switch state {
            case .failed(let error):
                gossipError("Gossip: Bonjour browser failed: \(error)")
            default:
                break
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        discovered.removeAll()
    }

    /// Re-delivers the currently visible peer set through `onPeersChanged` without waiting for the
    /// browse results to change. `TransportManager` only dials a known peer from that callback, and a
    /// peer that drops its connection while its Bonjour advertisement stays up never changes the
    /// results — so without this the Mac sat on "Searching for devices" indefinitely. Dialling is
    /// idempotent (already-connected / in-flight peers are skipped), so calling this on a timer is safe.
    func redeliverPeers() {
        queue.async { [weak self] in
            guard let self else { return }
            let peers = Array(self.discovered.values)
            DispatchQueue.main.async { [weak self] in
                self?.onPeersChanged?(peers)
            }
        }
    }

    private func handleResultsChanged(_ results: Set<NWBrowser.Result>) {
        var updated: [NWEndpoint: DiscoveredPeer] = [:]
        for result in results {
            guard case .bonjour(let txtRecord) = result.metadata,
                  let deviceId = txtRecord.getEntry(for: "deviceId").flatMap(Self.stringValue),
                  let fingerprint = txtRecord.getEntry(for: "fp").flatMap(Self.stringValue)
            else { continue }
            updated[result.endpoint] = DiscoveredPeer(deviceId: deviceId, publicKeyFingerprint: fingerprint, endpoint: result.endpoint)
        }
        discovered = updated
        let peers = Array(updated.values)
        DispatchQueue.main.async { [weak self] in
            self?.onPeersChanged?(peers)
        }
    }

    private static func stringValue(_ entry: NWTXTRecord.Entry) -> String? {
        if case .string(let s) = entry { return s }
        return nil
    }
}
