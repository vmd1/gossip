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
    /**
     * TODO: the operator has not picked the hosted relay's host yet. `.invalid` is a reserved TLD (RFC 2606) that can
     * never resolve, so this placeholder cannot connect to anything, and [isDefaultConfigured] is false until it is
     * replaced with the real `wss://host` (also add the host to [DEFAULT_HOSTS]).
     */
    const val DEFAULT_ORIGIN = "wss://relay.gossip.invalid"

    /** Hosts the app may connect to without the user typing them in. Keep in step with [DEFAULT_ORIGIN]. */
    val DEFAULT_HOSTS: Set<String> = setOf("relay.gossip.invalid")

    val isDefaultConfigured: Boolean
        get() {
            val origin = (normalizeOrigin(DEFAULT_ORIGIN, allowInsecureLoopback = false) as? Result.Ok)?.origin ?: return false
            val host = hostOf(origin) ?: return false
            return !host.endsWith(".invalid") && host in DEFAULT_HOSTS
        }

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

    /**
     * The origin to hand to the engine for these settings, or `null` when there is none (the placeholder default and no
     * custom address). A custom address replaces the default. An invalid custom address yields its [Result.Error].
     */
    fun resolveOrigin(customUrl: String, allowInsecureLoopback: Boolean = this.allowsInsecureLoopback): Result? {
        if (customUrl.isNotBlank()) return normalizeOrigin(customUrl, allowInsecureLoopback)
        if (!isDefaultConfigured) return null
        return normalizeOrigin(DEFAULT_ORIGIN, allowInsecureLoopback = false)
    }

    /**
     * Final check on the URL the engine asked to open (`RelayConnect`), right before the socket is created: `wss://` only,
     * to an allowlisted host (the default hosts, or the host of the origin the user configured). In a debug build `ws://`
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
        if (isDefaultConfigured && host in DEFAULT_HOSTS) return urlString
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
