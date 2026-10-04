package dev.vmd1.gossip.crypto

/**
 * Validates a user-entered fallback address: an IPv4 address, an IPv6 address (optional `%zone`),
 * or a DNS hostname — nothing else (no scheme, port, path or whitespace), since the value is dialed
 * repeatedly. Mac has the same rules (`HostValidator.swift`).
 */
object HostValidator {
    private val hostLabel = Regex("^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$")
    private val ipv6Chars = Regex("^[0-9A-Fa-f:.]+$")
    private val zone = Regex("^[A-Za-z0-9]+$")

    fun isValid(raw: String): Boolean {
        val host = raw.trim()
        if (host.isEmpty() || host.length > 253) return false
        return isIPv4(host) || isIPv6(host) || isHostname(host)
    }

    private fun isIPv4(s: String): Boolean {
        val parts = s.split('.')
        return parts.size == 4 && parts.all { it.length in 1..3 && it.all { c -> c in '0'..'9' } && it.toInt() <= 255 }
    }

    private fun isIPv6(s: String): Boolean {
        val pieces = s.split('%', limit = 2)
        if (pieces.size == 2 && !zone.matches(pieces[1])) return false
        val addr = pieces[0]
        if (addr.count { it == ':' } < 2 || !ipv6Chars.matches(addr)) return false
        // Literal-only parse (no DNS): InetAddress.getByName never resolves a string made of hex digits, ':' and '.'.
        return runCatching { java.net.InetAddress.getByName(addr) is java.net.Inet6Address }.getOrDefault(false)
    }

    private fun isHostname(s: String): Boolean {
        val labels = s.split('.')
        // A final all-numeric label can't be a real hostname; it's a malformed IPv4 address (256.1.1.1, 1.2.3).
        if (labels.last().all { it in '0'..'9' }) return false
        return labels.all { hostLabel.matches(it) }
    }
}
