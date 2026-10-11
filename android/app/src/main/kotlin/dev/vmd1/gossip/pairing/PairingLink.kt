package dev.vmd1.gossip.pairing

import java.util.Base64

/**
 * The typeable form of a pairing QR: `gossip-pair:` plus the base64url of the same JSON the QR carries. Used when a
 * device can't scan (no camera, no permission): the showing device offers it to copy, the other pastes it. It
 * carries exactly the QR's contents, so it is as sensitive as the QR (anyone holding it before it is used can start
 * a pairing, which the showing user must still confirm), and it is single use like the QR's token.
 *
 * Mac has the same codec (`PairingLink.swift`); both accept the raw JSON too, and ignore whitespace a chat app may
 * have added when wrapping the text.
 */
object PairingLink {
    const val PREFIX = "gossip-pair:"

    fun encode(json: String): String =
        PREFIX + Base64.getUrlEncoder().withoutPadding().encodeToString(json.toByteArray(Charsets.UTF_8))

    /** The payload JSON for [text] (a link or the raw JSON), or null when it is neither. */
    fun decode(text: String): String? {
        val trimmed = text.filterNot { it.isWhitespace() }
        if (trimmed.startsWith("{")) return text.trim()
        if (!trimmed.startsWith(PREFIX)) return null
        return try {
            String(Base64.getUrlDecoder().decode(trimmed.removePrefix(PREFIX)), Charsets.UTF_8)
        } catch (e: IllegalArgumentException) {
            null
        }
    }
}
