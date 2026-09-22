import Foundation
import Network

/// A discovered peer advertised over Bonjour.
struct DiscoveredPeer: Equatable {
    let deviceId: String
    let publicKeyFingerprint: String
    let endpoint: NWEndpoint
}

/// Advertises this Mac on the local network via Bonjour (`_connect._tcp`) and
/// discovers other Connect devices doing the same. Does not itself open a data
/// connection — `TransportManager` uses the endpoints this class surfaces to
/// dial out with `NWConnection`.
final class LocalDiscovery {
    static let serviceType = "_connect._tcp"

    /// Called on the main queue whenever the visible peer set changes.
    var onPeersChanged: (([DiscoveredPeer]) -> Void)?
    /// Called on the main queue when a remote peer connects to our advertised listener.
    var onIncomingConnection: ((NWConnection) -> Void)?

    private var listener: NWListener?
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.connect.app.localdiscovery")

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
                NSLog("Connect: Bonjour listener failed: \(error)")
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

        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handleResultsChanged(results)
        }
        browser.stateUpdateHandler = { state in
            switch state {
            case .failed(let error):
                NSLog("Connect: Bonjour browser failed: \(error)")
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
