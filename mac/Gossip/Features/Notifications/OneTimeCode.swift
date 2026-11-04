import Foundation

/// Finds a one-time login code (SMS/app 2FA) in a mirrored notification, so the Mac can offer to copy it.
/// Runs on the receiving device against text it already has; nothing new is sent anywhere. The Android twin is
/// `OneTimeCode.kt` and both share the cases in `schema/otp-cases.json`.
enum OneTimeCode {
    /// A word that says a number in the text is a login code. Without one, a bare number is never offered.
    private static let keyword = try! NSRegularExpression(
        pattern: #"(?i)\b(code|otp|passcode|password|verification|verify|2fa|two[- ]factor|one[- ]time|security|authenticat\w*|confirm\w*|login|log in|sign[- ]?in|pin)\b"#
    )
    /// 4-8 digits, optionally split in two by a space or dash (`123 456`, `123-456`), optionally prefixed `G-` (Google).
    private static let candidate = try! NSRegularExpression(
        pattern: #"(?<![\w.,:/+-])(?:G-)?(\d{3,4}[ -]?\d{2,4}|\d{4,8})(?![\w]|[.,:/%]\d)"#
    )

    static func detect(title: String, body: String) -> String? {
        let text = "\(title)\n\(body)"
        let whole = NSRange(text.startIndex..., in: text)
        guard keyword.firstMatch(in: text, range: whole) != nil else { return nil }
        for m in candidate.matches(in: text, range: whole) {
            guard let r = Range(m.range(at: 1), in: text) else { continue }
            let digits = text[r].filter(\.isNumber)
            guard (4...8).contains(digits.count) else { continue }
            if looksLikeNonCode(in: text, around: m.range, digits: String(digits)) { continue }
            return String(digits)
        }
        return nil
    }

    /// Years, money, times and phone-ish numbers that sit next to a keyword like "security" or "confirm".
    private static func looksLikeNonCode(in text: String, around range: NSRange, digits: String) -> Bool {
        let ns = text as NSString
        let before = ns.substring(with: NSRange(location: max(0, range.location - 3), length: min(3, range.location)))
        if before.contains("$") || before.contains("€") || before.contains("£") { return true }
        let afterStart = range.location + range.length
        let after = ns.substring(with: NSRange(location: afterStart, length: min(4, ns.length - afterStart))).lowercased()
        if after.hasPrefix(" am") || after.hasPrefix(" pm") || after.hasPrefix("am") || after.hasPrefix("pm") { return true }
        if after.hasPrefix(" usd") || after.hasPrefix(" eur") || after.hasPrefix(" gbp") { return true }
        return false
    }
}
