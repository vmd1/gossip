import Foundation

/// Validates a user-entered fallback address: an IPv4 address, an IPv6 address (optional `%zone`),
/// or a DNS hostname — nothing else (no scheme, port, path or whitespace), since the value is dialed
/// repeatedly. Android has the same rules (`HostValidator.kt`).
enum HostValidator {
    static func isValid(_ raw: String) -> Bool {
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        return isIPv4(host) || isIPv6(host) || isHostname(host)
    }

    private static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { p in
            !p.isEmpty && p.count <= 3 && p.allSatisfy(\.isASCII) && p.allSatisfy(\.isNumber) && (Int(p) ?? 256) <= 255
        }
    }

    private static func isIPv6(_ s: String) -> Bool {
        let base = s.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        if base.count == 2, base[1].isEmpty || !base[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) { return false }
        let addr = String(base[0])
        guard addr.filter({ $0 == ":" }).count >= 2, addr.allSatisfy({ $0.isASCII && ($0.isHexDigit || $0 == ":" || $0 == ".") }) else { return false }
        var storage = in6_addr()
        return inet_pton(AF_INET6, addr, &storage) == 1
    }

    private static func isHostname(_ s: String) -> Bool {
        let labels = s.split(separator: ".", omittingEmptySubsequences: false)
        // A final all-numeric label can't be a real hostname; it's a malformed IPv4 address (256.1.1.1, 1.2.3).
        if labels.last?.allSatisfy(\.isNumber) == true { return false }
        return !labels.isEmpty && labels.allSatisfy { l in
            !l.isEmpty && l.count <= 63 && !l.hasPrefix("-") && !l.hasSuffix("-")
                && l.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}
