package dev.vmd1.gossip.transport

import dev.vmd1.gossip.BuildConfig
import java.net.URI
import java.net.URISyntaxException

/**
 * Which relay addresses this app is willing to open a socket to. The Rust engine accepts any `ws(s)://` origin (it is
 * shell policy, see `desktop/README.md`); this is where the shell enforces `wss://` only plus a host allowlist in
 * release builds. Debug builds additionally allow plain `ws://` to localhost, 127.0.0.1 and 10.0.2.2 (the emulator's
 * alias for its host), for local development and the relay end-to-end test. Mirrors the Mac's `RelayEndpointPolicy`.
 *
 * Pure Kotlin (`java.net.URI`), so the JVM unit tests cover it.
 */
object RelayEndpointPolicy {
    /** The hosted relay. Also the fallback whenever there is no custom address and no directory answer. */
    const val DEFAULT_ORIGIN = "wss://gossip.vmd1.dev"

    /**
     * Hosts the app may connect to without the user typing them in: this domain and its subdomains. This is the same rule
     * the core applies to a relay named by the directory (`ALLOWED_RELAY_DOMAIN_SUFFIX`), so a directory can never send the
     * app anywhere else. The user's own custom address is a separate, explicit override.
     */
    const val ALLOWED_DOMAIN_SUFFIX = "vmd1.dev"

    fun isAllowedHost(host: String): Boolean = host == ALLOWED_DOMAIN_SUFFIX || host.endsWith(".$ALLOWED_DOMAIN_SUFFIX")

    /**
     * THE ONE PLACE to set the relay directory's HTTPS URL: an endpoint returning JSON with a `relayServer` key that names
     * the current relay. While it is this placeholder the app does not poll at all (that is not an error): it just uses
     * [DEFAULT_ORIGIN]. See `docs/plans/relay.md` "Relay directory".
     */
    const val DIRECTORY_ENDPOINT = "https://gossip.vmd1.dev/TODO-directory"

    fun isDirectoryPlaceholder(endpoint: String = DIRECTORY_ENDPOINT): Boolean = endpoint.endsWith("/TODO-directory")

    /** True only in debug builds. */
    val allowsInsecureLoopback: Boolean get() = BuildConfig.DEBUG

    enum class Failure { MALFORMED, INSECURE_SCHEME, CREDENTIALS_NOT_ALLOWED, UNEXPECTED_COMPONENTS, HOST_NOT_ALLOWED }

    sealed class Result {
        data class Ok(val origin: String) : Result()
        data class Error(val failure: Failure) : Result()
    }

    /** Plain `ws://` is only ever accepted for these hosts (and only in debug builds). 10.0.2.2 is the emulator's host. */
    fun isLoopback(host: String): Boolean = host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" || host == "10.0.2.2"

    /**
     * Parses an address typed by the user (or the default) into the `wss://host[:port]` form the engine signs into joins.
     * Accepts a trailing `/` or `/connect`; rejects credentials, queries, fragments and other paths, and `ws://` unless it
     * points at loopback in a debug build.
     */
    fun normalizeOrigin(text: String, allowInsecureLoopback: Boolean = this.allowsInsecureLoopback): Result {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return Result.Error(Failure.MALFORMED)
        val uri = try { URI(trimmed) } catch (e: URISyntaxException) { return Result.Error(Failure.MALFORMED) }
        val scheme = uri.scheme?.lowercase() ?: return Result.Error(Failure.MALFORMED)
        val rawHost = uri.host?.lowercase()?.takeIf { it.isNotEmpty() } ?: return Result.Error(Failure.MALFORMED)
        if (scheme != "wss" && scheme != "ws") return Result.Error(Failure.INSECURE_SCHEME)
        if (scheme == "ws" && !(allowInsecureLoopback && isLoopback(rawHost))) return Result.Error(Failure.INSECURE_SCHEME)
        if (uri.rawUserInfo != null) return Result.Error(Failure.CREDENTIALS_NOT_ALLOWED)
        if (uri.rawQuery != null || uri.rawFragment != null || uri.rawPath !in listOf("", "/", "/connect")) {
            return Result.Error(Failure.UNEXPECTED_COMPONENTS)
        }
        if (uri.port != -1 && uri.port !in 1..65535) return Result.Error(Failure.MALFORMED)
        val host = if (rawHost.contains(":") && !rawHost.startsWith("[")) "[$rawHost]" else rawHost
        val port = if (uri.port != -1) ":${uri.port}" else ""
        return Result.Ok("$scheme://$host$port")
    }

    enum class Source { CUSTOM, DIRECTORY, CACHED_OFFLINE, DEFAULT }

    data class Resolution(val origin: String, val source: Source) {
        val host: String get() = hostOf(origin) ?: origin
    }

    /**
     * The relay to use: the user's custom address, else the directory's `relayServer` (cached or freshly polled), else the
     * built-in default. `null` only for an invalid custom address, which is an error rather than a silent fallback.
     */
    fun resolve(
        customUrl: String,
        directoryOrigin: String? = null,
        directoryIsFresh: Boolean = false,
        allowInsecureLoopback: Boolean = this.allowsInsecureLoopback
    ): Resolution? {
        if (customUrl.isNotBlank()) {
            val ok = normalizeOrigin(customUrl, allowInsecureLoopback) as? Result.Ok ?: return null
            return Resolution(ok.origin, Source.CUSTOM)
        }
        if (directoryOrigin != null) {
            (normalizeOrigin(directoryOrigin, allowInsecureLoopback) as? Result.Ok)?.let {
                return Resolution(it.origin, if (directoryIsFresh) Source.DIRECTORY else Source.CACHED_OFFLINE)
            }
        }
        return Resolution((normalizeOrigin(DEFAULT_ORIGIN, allowInsecureLoopback = false) as Result.Ok).origin, Source.DEFAULT)
    }

    /**
     * Final check on the URL the engine asked to open (`RelayConnect`), right before the socket is created: `wss://` only,
     * to an allowlisted host (the vmd1.dev domain rule, or the host of the user's custom address). In a debug build `ws://`
     * is also allowed to loopback. Returns the URL to open, or `null`.
     */
    fun validateConnectUrl(
        urlString: String,
        customUrl: String,
        allowInsecureLoopback: Boolean = this.allowsInsecureLoopback
    ): String? {
        val uri = try { URI(urlString) } catch (e: URISyntaxException) { return null }
        val scheme = uri.scheme?.lowercase() ?: return null
        val host = uri.host?.lowercase()?.takeIf { it.isNotEmpty() } ?: return null
        if (uri.rawUserInfo != null || uri.rawFragment != null) return null
        if (scheme == "ws") return if (allowInsecureLoopback && isLoopback(host)) urlString else null
        if (scheme != "wss") return null
        if (isAllowedHost(host)) return urlString
        val custom = customUrl.trim()
        if (custom.isNotEmpty()) {
            val origin = (normalizeOrigin(custom, allowInsecureLoopback = false) as? Result.Ok)?.origin
            if (origin != null && hostOf(origin) == host) return urlString
        }
        return null
    }

    /** A line safe to log: the host only, never the path, query or any token. */
    fun loggable(urlString: String): String = hostOf(urlString) ?: "relay"

    private fun hostOf(urlString: String): String? = try { URI(urlString).host?.lowercase() } catch (e: URISyntaxException) { null }
}
