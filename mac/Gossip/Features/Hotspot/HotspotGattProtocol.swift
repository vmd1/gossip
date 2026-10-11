import Foundation
import CryptoKit
import CoreBluetooth
import GossipCoreKit

/// Wire-level contract for Instant Hotspot's BLE GATT control channel — see `docs/ble-hotspot-protocol.md`. This travels over a
/// raw GATT service, not the Noise-encrypted Wi-Fi mesh transport, since the whole point of Instant Hotspot is reaching a device
/// with no IP connectivity at all.
///
/// The codec itself (the UUIDs, chunking, the signed request and status payloads, the AES-GCM credential blob, the shared-key
/// derivation and the replay/rate gate) is the core's (`desktop/core/src/features/hotspot_gatt.rs`), shared byte for byte with
/// Android; this file keeps the app-facing types and delegates to it.
enum HotspotGattProtocol {
    static let serviceUUID = CBUUID(string: GossipCoreKit.hotspotServiceUuid())
    static let requestCharacteristicUUID = CBUUID(string: GossipCoreKit.hotspotRequestCharacteristicUuid())
    static let responseCharacteristicUUID = CBUUID(string: GossipCoreKit.hotspotResponseCharacteristicUuid())

    /// Payload bytes per GATT write/notify chunk (never depends on MTU negotiation).
    static let chunkPayloadSize = 19
    /// Requests and responses are a few hundred bytes; anything larger is not a real message.
    static let maxMessageBytes = 4096

    static func encodeChunks(_ message: Data) -> [Data] { GossipCoreKit.hotspotEncodeChunks(message: message) }

    /// Reassembles chunks written/notified one at a time back into the original message (discarding anything over
    /// `maxMessageBytes`). Not thread-safe by design: callers own serializing chunk delivery per connection.
    final class ChunkReassembler {
        private let core = GossipCoreKit.HotspotChunkReassembler()

        /// Feeds one chunk; returns the complete message once the last chunk arrives, or `nil` if more are expected.
        func feed(_ chunk: Data) -> Data? { core.feed(chunk: chunk) }
    }

    struct ToggleRequestPayload: Codable, Equatable {
        let id: String
        let en: Bool
        let n: String
        /// Requester's clock, Unix ms, signed: bounds how long a captured request stays replayable.
        let t: Int64
        let s: String

        fileprivate init(_ core: GossipCoreKit.HotspotToggleRequest) {
            self.init(id: core.id, en: core.en, n: core.n, t: core.t, s: core.s)
        }

        init(id: String, en: Bool, n: String, t: Int64, s: String) {
            self.id = id; self.en = en; self.n = n; self.t = t; self.s = s
        }

        fileprivate var core: GossipCoreKit.HotspotToggleRequest {
            GossipCoreKit.HotspotToggleRequest(id: id, en: en, n: n, t: t, s: s)
        }

        /// Builds and signs a fresh request. [signingKey] is the requester's Ed25519 signing key (`IdentityKeyStore.signingKey`).
        static func create(requesterId: String, enable: Bool, signingKey: Curve25519.Signing.PrivateKey) -> ToggleRequestPayload {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            // A 32-byte seed is always valid, so this cannot fail.
            let core = try! GossipCoreKit.hotspotRequestCreate(requesterId: requesterId, enable: enable, nonce: UUID().uuidString,
                                                               nowMs: now, signingSeed: signingKey.rawRepresentation)
            return ToggleRequestPayload(core)
        }

        func isSignatureValid(signingPublicKeyBase64: String) -> Bool {
            GossipCoreKit.hotspotRequestVerify(request: core, signingPublicKeyB64: signingPublicKeyBase64)
        }

        /// Whether the signed clock is inside the freshness window.
        func isFresh(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> Bool {
            GossipCoreKit.hotspotRequestIsFresh(request: core, nowMs: nowMs)
        }
    }

    /// `cred`, when present, is base64(12-byte AES-GCM nonce || ciphertext+tag) encrypting the SSID and passphrase. Signed over the
    /// *ciphertext*, so the signature also protects its integrity end to end, on top of AES-GCM's own tag.
    struct StatusPayload: Codable, Equatable {
        let id: String
        let ok: Bool
        let n: String
        let s: String
        let cred: String?

        fileprivate init(_ core: GossipCoreKit.HotspotStatus) {
            self.init(id: core.id, ok: core.ok, n: core.n, s: core.s, cred: core.cred)
        }

        init(id: String, ok: Bool, n: String, s: String, cred: String?) {
            self.id = id; self.ok = ok; self.n = n; self.s = s; self.cred = cred
        }

        fileprivate var core: GossipCoreKit.HotspotStatus {
            GossipCoreKit.HotspotStatus(id: id, ok: ok, n: n, s: s, cred: cred)
        }

        func isSignatureValid(signingPublicKeyBase64: String) -> Bool {
            GossipCoreKit.hotspotStatusVerify(status: core, signingPublicKeyB64: signingPublicKeyBase64)
        }

        /// Decrypts `cred` with the shared secret derived between this device and the provider. Returns `nil` if there was no
        /// credential blob or decryption fails (wrong key, tampered ciphertext). Callers must check `isSignatureValid` first.
        func decryptCredentials(sharedSecretKey: SymmetricKey) -> (ssid: String, passphrase: String)? {
            guard cred != nil else { return nil }
            let key = sharedSecretKey.withUnsafeBytes { Data($0) }
            guard let login = try? GossipCoreKit.hotspotStatusDecrypt(status: core, sharedKey: key) else { return nil }
            return (login.ssid, login.passphrase)
        }
    }

    /// `SHA-256(DH(local, remote) || "connect-hotspot-gatt-v1")`: the label keeps it from ever colliding with the Noise session key
    /// the same keypair derives. Byte-for-byte the same on Android (both are the core's). `nil` for a degenerate peer key.
    static func deriveSharedSecretKey(localAgreementKey: Curve25519.KeyAgreement.PrivateKey, remotePublicKey: Curve25519.KeyAgreement.PublicKey) -> SymmetricKey? {
        guard let key = try? GossipCoreKit.hotspotDeriveSharedKey(
            localX25519Secret: localAgreementKey.rawRepresentation, remoteX25519Public: remotePublicKey.rawRepresentation
        ) else { return nil }
        return SymmetricKey(data: key)
    }

    static func encodeRequest(_ payload: ToggleRequestPayload) -> Data { GossipCoreKit.hotspotRequestEncode(request: payload.core) }

    static func decodeRequest(_ data: Data) -> ToggleRequestPayload? {
        GossipCoreKit.hotspotRequestDecode(data: data).map(ToggleRequestPayload.init)
    }

    static func encodeStatus(_ payload: StatusPayload) -> Data { GossipCoreKit.hotspotStatusEncode(status: payload.core) }

    static func decodeStatus(_ data: Data) -> StatusPayload? {
        GossipCoreKit.hotspotStatusDecode(data: data).map(StatusPayload.init)
    }

    static func makeStatusPayload(
        providerId: String,
        enabled: Bool,
        nonce: String,
        signingKey: Curve25519.Signing.PrivateKey,
        sharedSecretKey: SymmetricKey? = nil,
        ssid: String? = nil,
        passphrase: String? = nil
    ) -> StatusPayload {
        var credentials: GossipCoreKit.HotspotCredentials?
        if let ssid, let passphrase, let sharedSecretKey {
            credentials = GossipCoreKit.HotspotCredentials(
                ssid: ssid, passphrase: passphrase,
                sharedKey: sharedSecretKey.withUnsafeBytes { Data($0) }, gcmNonce: GossipCoreKit.randomBytes(len: 12)
            )
        }
        let core = try! GossipCoreKit.hotspotStatusCreate(providerId: providerId, enabled: enabled, nonce: nonce,
                                                          signingSeed: signingKey.rawRepresentation, credentials: credentials)
        return StatusPayload(core)
    }
}
