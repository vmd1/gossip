import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

/// The JSON payload encoded into the pairing QR code. The scanning device reads this to
/// learn the displaying device's identity + static public key out-of-band, which is what
/// lets the subsequent Noise_IK handshake use IK (rather than the more expensive XX
/// pattern) even on the very first connection. Either platform can be the responder
/// showing this QR — Mac (as originally built) or, since mesh support, an Android
/// device pairing directly with another Android device — hence generic field names
/// rather than `mac*`; this is not part of the wire envelope (`schema/message-types.md`)
/// and both platforms' QR generator/scanner just need to agree on this shape.
struct PairingQRPayload: Codable {
    let responderDeviceId: String
    let responderPublicKeyFingerprint: String
    /// Base64-encoded raw X25519 static public key, so the scanning device can dial in as the Noise_IK initiator.
    let responderPublicKey: String
    /// So the scanning device can record the right name/type in its own `TrustedDevices`
    /// row without hardcoding an assumption about which platform is displaying the QR.
    let responderDeviceName: String
    let responderDeviceType: String
    /// Random nonce identifying this specific pairing attempt; the scanning device should
    /// echo it back (out of band, e.g. in its own confirmation UI) so the user
    /// can visually confirm they scanned the right code.
    let pairingToken: String
    /// Base64 Ed25519 signing public key — see `HandshakePayload`'s `signingPublicKey`
    /// field on Android / the `signingPublicKey` envelope field here. Carried here too
    /// (not just over the handshake) because the *initiator* (the device scanning this
    /// QR) never receives a `HandshakePeerInfo` back from a fire-and-forget connect
    /// call; it only learns the responder's identity from this payload.
    let responderSigningPublicKey: String
}

enum QRCodeGenerator {
    /// Builds the pairing QR payload for this Mac.
    static func makePairingPayload(identity: IdentityKeyStore = .shared) -> PairingQRPayload {
        PairingQRPayload(
            responderDeviceId: identity.deviceId,
            responderPublicKeyFingerprint: identity.publicKeyFingerprint,
            responderPublicKey: identity.agreementKey.publicKey.rawRepresentation.base64EncodedString(),
            responderDeviceName: Host.current().localizedName ?? "Mac",
            responderDeviceType: DeviceType.mac.rawValue,
            pairingToken: UUID().uuidString,
            responderSigningPublicKey: identity.signingKey.publicKey.rawRepresentation.base64EncodedString()
        )
    }

    /// Renders a QR code image encoding the JSON of `payload`.
    static func image(for payload: PairingQRPayload, scale: CGFloat = 8) -> NSImage? {
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return image(forData: data, scale: scale)
    }

    static func image(forData data: Data, scale: CGFloat = 8) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return nil }
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        let scaledImage = outputImage.transformed(by: transform)

        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaledImage.extent.width, height: scaledImage.extent.height))
    }
}
