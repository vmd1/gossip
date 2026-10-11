import Foundation

/// The typeable form of a pairing QR: `gossip-pair:` plus the base64url of the same JSON the QR carries. Used when a
/// device can't scan: the showing device offers it to copy, the other pastes it. It carries exactly the QR's
/// contents, so it is as sensitive as the QR (the showing user must still confirm any pairing it starts).
///
/// Android has the same codec (`PairingLink.kt`); both accept the raw JSON too, and ignore whitespace a chat app may
/// have added when wrapping the text.
enum PairingLink {
    static let prefix = "gossip-pair:"

    static func encode(json: Data) -> String {
        prefix + json.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The payload JSON for `text` (a link or the raw JSON), or nil when it is neither.
    static func decode(_ text: String) -> Data? {
        let compact = String(text.filter { !$0.isWhitespace })
        if compact.hasPrefix("{") { return text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) }
        guard compact.hasPrefix(prefix) else { return nil }
        var body = String(compact.dropFirst(prefix.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while body.count % 4 != 0 { body += "=" }
        return Data(base64Encoded: body)
    }
}
