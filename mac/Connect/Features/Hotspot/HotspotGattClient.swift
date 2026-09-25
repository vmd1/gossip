import Foundation
import CoreBluetooth
import CryptoKit

/// The GATT *central* (client) side of Instant Hotspot's control channel — Mac only ever
/// requests, never provides (see `docs/ble-hotspot-protocol.md`'s "GATT roles"). Owns its
/// own `CBCentralManager` instance, deliberately separate from
/// `BLEProximityMonitor`'s continuous scan — CoreBluetooth peripheral objects are scoped
/// to the manager instance that discovered them, so this class re-resolves a peripheral
/// from its stable `identifier` (via `BLEProximityMonitor.peripheralIdentifierByDeviceId`)
/// rather than sharing a `CBPeripheral` object across manager instances.
final class HotspotGattClient: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    enum Result {
        case success(enabled: Bool, ssid: String?, passphrase: String?)
        case failed(String)
    }

    private let identity: IdentityKeyStore
    private let trustedDevices: TrustedDevicesStore
    private var centralManager: CBCentralManager!

    private var peripheral: CBPeripheral?
    private var requestCharacteristic: CBCharacteristic?
    private var responseCharacteristic: CBCharacteristic?
    private let reassembler = HotspotGattProtocol.ChunkReassembler()
    private var outboundQueue: [Data] = []
    private var sendInFlight = false
    private var completion: ((Result) -> Void)?
    private var timeoutWorkItem: DispatchWorkItem?
    private var signingPublicKeyBase64: String?
    private var sharedSecretKey: SymmetricKey?
    private var pendingRequest: HotspotGattProtocol.ToggleRequestPayload?
    private var pendingPeripheralIdentifier: UUID?

    init(identity: IdentityKeyStore = .shared, trustedDevices: TrustedDevicesStore = .shared) {
        self.identity = identity
        self.trustedDevices = trustedDevices
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    /// Connects to `providerId` (already known, via `BLEProximityMonitor`, to be
    /// trusted and nearby), sends a signed `hotspot.toggle_request`, and waits for a
    /// verified, decrypted `hotspot.status` response. Only one request may be in
    /// flight per `HotspotGattClient` instance at a time — callers wanting concurrent
    /// requests to different providers should use separate instances.
    func requestToggle(
        providerId: String,
        peripheralIdentifier: UUID,
        enable: Bool,
        timeoutSeconds: TimeInterval = 15,
        completion: @escaping (Result) -> Void
    ) {
        guard self.completion == nil else {
            completion(.failed("A request is already in flight on this client"))
            return
        }
        guard let provider = trustedDevices.device(for: providerId), let signingKey = provider.signingPublicKeyBase64 else {
            completion(.failed("Provider not trusted or missing a signing key (may need to re-pair)"))
            return
        }
        guard let providerPublicKeyData = Data(base64Encoded: provider.publicKeyBase64),
              let providerPublicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: providerPublicKeyData)
        else {
            completion(.failed("Provider's stored public key is invalid"))
            return
        }

        self.completion = completion
        self.signingPublicKeyBase64 = signingKey
        self.sharedSecretKey = HotspotGattProtocol.deriveSharedSecretKey(localAgreementKey: identity.agreementKey, remotePublicKey: providerPublicKey)
        self.pendingRequest = HotspotGattProtocol.ToggleRequestPayload.create(requesterId: identity.deviceId, enable: enable, signingKey: identity.signingKey)
        self.pendingPeripheralIdentifier = peripheralIdentifier

        let work = DispatchWorkItem { [weak self] in self?.settle(.failed("Timed out waiting for a response")) }
        timeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds, execute: work)

        // A freshly-created `CBCentralManager` starts in `.unknown` and only reports
        // `.poweredOn` asynchronously via `centralManagerDidUpdateState` — checking
        // `.state` synchronously right after `init` here would almost always see
        // `.unknown` even though Bluetooth genuinely is on, since there's been no time
        // for CoreBluetooth to deliver that first callback yet (confirmed live: this
        // was a real bug, not a hypothetical one — every request failed immediately
        // with "Bluetooth is not powered on" before this fix). If already powered on
        // (a reused, longer-lived client instance), proceed immediately; otherwise wait
        // for the callback — the timeout above still bounds the total wait either way.
        if centralManager.state == .poweredOn {
            beginConnecting()
        }
    }

    private func beginConnecting() {
        guard let peripheralIdentifier = pendingPeripheralIdentifier else { return }
        let peripherals = centralManager.retrievePeripherals(withIdentifiers: [peripheralIdentifier])
        guard let target = peripherals.first else {
            settle(.failed("Could not resolve a peripheral for this device"))
            return
        }
        peripheral = target
        target.delegate = self
        centralManager.connect(target, options: nil)
    }

    private func settle(_ result: Result) {
        guard let completion else { return }
        self.completion = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        if let peripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        requestCharacteristic = nil
        responseCharacteristic = nil
        outboundQueue = []
        sendInFlight = false
        pendingRequest = nil
        pendingPeripheralIdentifier = nil
        completion(result)
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn, completion != nil, peripheral == nil, pendingRequest != nil else { return }
        beginConnecting()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([HotspotGattProtocol.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        settle(.failed("Failed to connect: \(error?.localizedDescription ?? "unknown error")"))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // A clean disconnect after we already settled (normal teardown from `settle`
        // itself) is expected and must not re-settle; `completion` is nil by then.
        settle(.failed("Disconnected before a response was received"))
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == HotspotGattProtocol.serviceUUID }) else {
            settle(.failed("Hotspot GATT service not found on this device"))
            return
        }
        peripheral.discoverCharacteristics(
            [HotspotGattProtocol.requestCharacteristicUUID, HotspotGattProtocol.responseCharacteristicUUID],
            for: service
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else {
            settle(.failed("No characteristics found on hotspot GATT service"))
            return
        }
        guard let foundRequestCharacteristic = characteristics.first(where: { $0.uuid == HotspotGattProtocol.requestCharacteristicUUID }),
              let foundResponseCharacteristic = characteristics.first(where: { $0.uuid == HotspotGattProtocol.responseCharacteristicUUID }),
              pendingRequest != nil
        else {
            settle(.failed("Hotspot GATT characteristics not found on this device"))
            return
        }
        requestCharacteristic = foundRequestCharacteristic
        responseCharacteristic = foundResponseCharacteristic
        // Deliberately does NOT start writing the request here — see
        // `peripheral(_:didUpdateNotificationStateFor:error:)`. Live-confirmed real
        // bug: starting the write immediately after calling `setNotifyValue` races the
        // subscription actually taking effect. When the phone responded fast enough,
        // its response notifications arrived before the subscribe had gone through, so
        // every response chunk was silently dropped — the toggle genuinely happened
        // server-side, but the client waited the full timeout and reported failure
        // anyway, having received nothing.
        peripheral.setNotifyValue(true, for: foundResponseCharacteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == HotspotGattProtocol.responseCharacteristicUUID else { return }
        if let error {
            settle(.failed("Could not subscribe to hotspot status notifications: \(error.localizedDescription)"))
            return
        }
        guard characteristic.isNotifying, let requestCharacteristic, let request = pendingRequest else { return }
        outboundQueue = HotspotGattProtocol.encodeChunks(HotspotGattProtocol.encodeRequest(request))
        drainOutbound(peripheral, requestCharacteristic)
    }

    private func drainOutbound(_ peripheral: CBPeripheral, _ characteristic: CBCharacteristic) {
        guard !sendInFlight, !outboundQueue.isEmpty else { return }
        let chunk = outboundQueue.removeFirst()
        sendInFlight = true
        peripheral.writeValue(chunk, for: characteristic, type: .withResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        sendInFlight = false
        if let error {
            settle(.failed("Write failed: \(error.localizedDescription)"))
            return
        }
        if let requestCharacteristic, characteristic.uuid == requestCharacteristic.uuid {
            drainOutbound(peripheral, requestCharacteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == HotspotGattProtocol.responseCharacteristicUUID, let data = characteristic.value else { return }
        guard let complete = reassembler.feed(data) else { return }
        guard let status = HotspotGattProtocol.decodeStatus(complete), let signingKey = signingPublicKeyBase64,
              status.isSignatureValid(signingPublicKeyBase64: signingKey)
        else {
            settle(.failed("Malformed or unverifiable hotspot.status response"))
            return
        }
        let decrypted = sharedSecretKey.flatMap { status.decryptCredentials(sharedSecretKey: $0) }
        settle(.success(enabled: status.ok, ssid: decrypted?.ssid, passphrase: decrypted?.passphrase))
    }
}
