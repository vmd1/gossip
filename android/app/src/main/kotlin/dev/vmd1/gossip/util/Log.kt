package dev.vmd1.gossip.util

import dev.vmd1.gossip.BuildConfig

/**
 * Drop-in for `android.util.Log`. Verbose, debug and info messages are logged only in debug builds, so the app
 * that ships writes none of the diagnostics (addresses, session ids, network names...) the code logs while
 * developing. Warnings and errors, which report failures, are always logged, with IP addresses redacted. Call sites keep the familiar
 * `Log.i(TAG, ...)` shape, only the import differs.
 */
object Log {
    @JvmStatic fun v(tag: String, msg: String): Int = if (BuildConfig.DEBUG) android.util.Log.v(tag, msg) else 0
    @JvmStatic fun d(tag: String, msg: String): Int = if (BuildConfig.DEBUG) android.util.Log.d(tag, msg) else 0
    @JvmStatic fun d(tag: String, msg: String, tr: Throwable?): Int = if (BuildConfig.DEBUG) android.util.Log.d(tag, msg, tr) else 0
    @JvmStatic fun i(tag: String, msg: String): Int = if (BuildConfig.DEBUG) android.util.Log.i(tag, msg) else 0
    @JvmStatic fun i(tag: String, msg: String, tr: Throwable?): Int = if (BuildConfig.DEBUG) android.util.Log.i(tag, msg, tr) else 0

    @JvmStatic fun w(tag: String, msg: String): Int = android.util.Log.w(tag, redactAddresses(msg))
    @JvmStatic fun w(tag: String, msg: String, tr: Throwable?): Int = android.util.Log.w(tag, redactAddresses(msg), tr)
    @JvmStatic fun w(tag: String, tr: Throwable?): Int = android.util.Log.w(tag, tr)
    @JvmStatic fun e(tag: String, msg: String): Int = android.util.Log.e(tag, redactAddresses(msg))
    @JvmStatic fun e(tag: String, msg: String, tr: Throwable?): Int = android.util.Log.e(tag, redactAddresses(msg), tr)

    private val addressPattern = Regex(
        """(?:\b\d{1,3}(?:\.\d{1,3}){3}\b)|(?:\b(?:[0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}\b)|(?:[0-9a-fA-F:]*::[0-9a-fA-F:.]*(?:%[A-Za-z0-9]+)?)"""
    )

    /** Replaces IP addresses (error descriptions often embed the peer's) with `<address>` before a message is persisted. */
    @JvmStatic fun redactAddresses(message: String): String = addressPattern.replace(message, "<address>")
}
