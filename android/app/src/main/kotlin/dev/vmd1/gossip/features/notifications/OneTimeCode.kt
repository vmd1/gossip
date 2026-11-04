package dev.vmd1.gossip.features.notifications

/**
 * Finds a one-time login code (SMS/app 2FA) in a mirrored notification, so the device can offer to copy it. Runs on text the
 * device already has; nothing new is sent anywhere. The Mac twin is `OneTimeCode.swift`; both pass `schema/otp-cases.json`.
 */
object OneTimeCode {
    /** A word that says a number in the text is a login code. Without one, a bare number is never offered. */
    private val keyword = Regex(
        """\b(code|otp|passcode|password|verification|verify|2fa|two[- ]factor|one[- ]time|security|authenticat\w*|confirm\w*|login|log in|sign[- ]?in|pin)\b""",
        RegexOption.IGNORE_CASE
    )
    /** 4-8 digits, optionally split in two by a space or dash (`123 456`, `123-456`), optionally prefixed `G-` (Google). */
    private val candidate = Regex("""(?<![\w.,:/+-])(?:G-)?(\d{3,4}[ -]?\d{2,4}|\d{4,8})(?!\w|[.,:/%]\d)""")

    fun detect(title: String, body: String): String? {
        val text = "$title\n$body"
        if (!keyword.containsMatchIn(text)) return null
        for (m in candidate.findAll(text)) {
            val digits = m.groupValues[1].filter { it.isDigit() }
            if (digits.length !in 4..8) continue
            if (looksLikeNonCode(text, m.range, digits)) continue
            return digits
        }
        return null
    }

    /** Money and times that sit next to a keyword like "security" or "confirm". */
    private fun looksLikeNonCode(text: String, range: IntRange, @Suppress("UNUSED_PARAMETER") digits: String): Boolean {
        val before = text.substring(maxOf(0, range.first - 3), range.first)
        if (before.any { it == '$' || it == '\u20ac' || it == '\u00a3' }) return true
        val after = text.substring(range.last + 1, minOf(text.length, range.last + 5)).lowercase()
        return after.startsWith(" am") || after.startsWith(" pm") || after.startsWith("am") || after.startsWith("pm") ||
            after.startsWith(" usd") || after.startsWith(" eur") || after.startsWith(" gbp")
    }
}
