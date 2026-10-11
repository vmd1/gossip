import Foundation

/// Which relay addresses this app is willing to open a socket to. The Rust engine accepts any `ws(s)://` origin (it is
/// shell policy, see `desktop/README.md`); this is where the shell enforces `wss://` only in release
/// builds, whichever host the user or the directory names. Debug builds additionally allow plain `ws://` to the loopback addresses, for local development and
/// the relay end-to-end test.
enum RelayEndpointPolicy {
    /// The hosted relay. Also the fallback whenever there is no custom address and no directory answer.
    static let defaultOrigin = "wss://gossip.vmd1.dev"

    /// THE ONE PLACE to set the relay directory's HTTPS URL: an endpoint returning JSON with a `relayServer` key that
    /// names the current relay. While it is this placeholder the app does not poll at all (that is not an error): it
    /// just uses `defaultOrigin`. See `docs/plans/relay.md` "Relay directory".
    static let directoryEndpoint = "https://api.vmd1.dev/v1/config/gossip"

    static var directoryEndpointIsPlaceholder: Bool { directoryEndpoint.hasSuffix("/TODO-directory") }

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

    enum Source: Equatable {
        /// The user's own address.
        case custom
        /// A directory answer fetched in this run, on its last attempt.
        case directory
        /// The last good directory answer kept on disk, while the directory is unreachable or not yet refreshed.
        case cachedOffline
        case builtInDefault
    }

    struct Resolution: Equatable {
        let origin: String
        let source: Source
        var host: String { URLComponents(string: origin)?.host ?? origin }
    }

    /// The relay to use: the user's custom address, else the directory's `relayServer` (cached or freshly polled), else
    /// the built-in default. An invalid custom address is an error rather than a silent fallback.
    static func resolve(customURL: String, directoryOrigin: String?, directoryIsFresh: Bool = false,
                        allowInsecureLoopback: Bool = RelayEndpointPolicy.allowsInsecureLoopback) -> Result<Resolution, Failure> {
        if !customURL.trimmingCharacters(in: .whitespaces).isEmpty {
            return normalizeOrigin(customURL, allowInsecureLoopback: allowInsecureLoopback).map { Resolution(origin: $0, source: .custom) }
        }
        if let directoryOrigin, case .success(let origin) = normalizeOrigin(directoryOrigin, allowInsecureLoopback: allowInsecureLoopback) {
            return .success(Resolution(origin: origin, source: directoryIsFresh ? .directory : .cachedOffline))
        }
        guard case .success(let origin) = normalizeOrigin(defaultOrigin, allowInsecureLoopback: false) else { return .failure(.malformed) }
        return .success(Resolution(origin: origin, source: .builtInDefault))
    }

    /// Final check on the URL the engine asked to open (`RelayConnect`), right before the socket is created: `wss://`
    /// only, to whatever host was configured. In a Debug build `ws://` is also allowed to loopback.
    static func validateConnectURL(_ urlString: String,
                                   allowInsecureLoopback: Bool = RelayEndpointPolicy.allowsInsecureLoopback) -> URL? {
        guard let parts = URLComponents(string: urlString), let scheme = parts.scheme?.lowercased(),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              let url = parts.url else { return nil }
        if scheme == "ws" { return allowInsecureLoopback && isLoopback(host) ? url : nil }
        return scheme == "wss" ? url : nil
    }

    /// A line safe to log: the host only, never the path, query or any token.
    static func loggable(_ url: URL) -> String { url.host ?? "relay" }
}
