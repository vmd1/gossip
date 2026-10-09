import Foundation

/// Which relay addresses this app is willing to open a socket to. The Rust engine accepts any `ws(s)://` origin (it is
/// shell policy, see `desktop/README.md`); this is where the shell enforces `wss://` only plus a host allowlist in
/// release builds. Debug builds additionally allow plain `ws://` to the loopback addresses, for local development and
/// the relay end-to-end test.
enum RelayEndpointPolicy {
    /// TODO: the operator has not picked the hosted relay's host yet. `.invalid` is a reserved TLD (RFC 2606) that can
    /// never resolve, so this placeholder cannot connect to anything, and `isDefaultConfigured` is false until it is
    /// replaced with the real `wss://host` (also add the host to `defaultHosts`).
    static let defaultOrigin = "wss://relay.gossip.invalid"

    /// Hosts the app may connect to without the user typing them in. Keep in step with `defaultOrigin`.
    static let defaultHosts: Set<String> = ["relay.gossip.invalid"]

    static var isDefaultConfigured: Bool {
        guard case .success(let origin) = normalizeOrigin(defaultOrigin, allowInsecureLoopback: false),
              let host = URLComponents(string: origin)?.host else { return false }
        return !host.hasSuffix(".invalid") && defaultHosts.contains(host)
    }

    #if DEBUG
    static let allowsInsecureLoopback = true
    #else
    static let allowsInsecureLoopback = false
    #endif

    enum Failure: Error, Equatable {
        case malformed
        case insecureScheme
        case credentialsNotAllowed
        case unexpectedComponents
        case hostNotAllowed
    }

    static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    /// Parses an address typed by the user (or the default) into the `wss://host[:port]` form the engine signs into
    /// joins. Accepts a trailing `/` or `/connect`; rejects credentials, queries, fragments and other paths, and `ws://`
    /// unless it points at loopback in a Debug build.
    static func normalizeOrigin(_ text: String, allowInsecureLoopback: Bool = RelayEndpointPolicy.allowsInsecureLoopback) -> Result<String, Failure> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let parts = URLComponents(string: trimmed),
              let scheme = parts.scheme?.lowercased(), let rawHost = parts.host?.lowercased(), !rawHost.isEmpty
        else { return .failure(.malformed) }
        guard scheme == "wss" || scheme == "ws" else { return .failure(.insecureScheme) }
        if scheme == "ws" && !(allowInsecureLoopback && isLoopback(rawHost)) { return .failure(.insecureScheme) }
        guard parts.user == nil, parts.password == nil else { return .failure(.credentialsNotAllowed) }
        guard parts.query == nil, parts.fragment == nil, ["", "/", "/connect"].contains(parts.path) else {
            return .failure(.unexpectedComponents)
        }
        if let port = parts.port, !(1...65535).contains(port) { return .failure(.malformed) }
        let host = rawHost.contains(":") ? "[\(rawHost)]" : rawHost
        return .success("\(scheme)://\(host)\(parts.port.map { ":\($0)" } ?? "")")
    }

    /// The origin to hand to the engine for these settings, or why there is none. A custom address replaces the default.
    static func resolveOrigin(customURL: String, allowInsecureLoopback: Bool = RelayEndpointPolicy.allowsInsecureLoopback) -> Result<String, Failure>? {
        if !customURL.trimmingCharacters(in: .whitespaces).isEmpty {
            return normalizeOrigin(customURL, allowInsecureLoopback: allowInsecureLoopback)
        }
        guard isDefaultConfigured else { return nil }
        return normalizeOrigin(defaultOrigin, allowInsecureLoopback: false)
    }

    /// Final check on the URL the engine asked to open (`RelayConnect`), right before the socket is created: `wss://`
    /// only, to an allowlisted host (the default hosts, or the host of the user's own custom address). In a Debug build
    /// `ws://` is also allowed to loopback.
    static func validateConnectURL(_ urlString: String, customURL: String,
                                   allowInsecureLoopback: Bool = RelayEndpointPolicy.allowsInsecureLoopback) -> URL? {
        guard let parts = URLComponents(string: urlString), let scheme = parts.scheme?.lowercased(),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              let url = parts.url else { return nil }
        if scheme == "ws" { return allowInsecureLoopback && isLoopback(host) ? url : nil }
        guard scheme == "wss" else { return nil }
        if isDefaultConfigured && defaultHosts.contains(host) { return url }
        let custom = customURL.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty, case .success(let origin) = normalizeOrigin(custom, allowInsecureLoopback: false),
           let customHost = URLComponents(string: origin)?.host, customHost == host { return url }
        return nil
    }

    /// A line safe to log: the host only, never the path, query or any token.
    static func loggable(_ url: URL) -> String { url.host ?? "relay" }
}
