import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

/// The JSON payload encoded into the pairing QR code. The phone scans this to
/// learn the Mac's identity + static public key out-of-band, which is what
/// lets the subsequent Noise_IK handshake use IK (rather than the more
/// expensive XX pattern) even on the very first connection.
struct PairingQRPayload: Codable {
    let macDeviceId: String
    let macPublicKeyFingerprint: String
    /// Base64-encoded raw X25519 static public key, so the phone can dial in as the Noise_IK initiator.
    let macPublicKey: String
    /// Random nonce identifying this specific pairing attempt; the phone should
    /// echo it back (out of band, e.g. in its own confirmation UI) so the user
    /// can visually confirm they scanned the right code.
    let pairingToken: String
}

enum QRCodeGenerator {
    /// Builds the pairing QR payload for this Mac.
    static func makePairingPayload(identity: IdentityKeyStore = .shared) -> PairingQRPayload {
        PairingQRPayload(
            macDeviceId: identity.deviceId,
            macPublicKeyFingerprint: identity.publicKeyFingerprint,
            macPublicKey: identity.agreementKey.publicKey.rawRepresentation.base64EncodedString(),
            pairingToken: UUID().uuidString
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
