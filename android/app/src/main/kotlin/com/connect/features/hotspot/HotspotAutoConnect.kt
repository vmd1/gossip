package com.connect.features.hotspot

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.util.Log

private const val TAG = "HotspotAutoConnect"

/**
 * Joins a Wi-Fi network given SSID+passphrase credentials received over Instant
 * Hotspot's GATT channel (`docs/ble-hotspot-protocol.md`) — the requesting side's half
 * of credential auto-connect, for an Android **tablet or phone** requester (Mac's
 * equivalent is `HotspotAutoConnect.swift`/`CWInterface.associate`).
 *
 * Uses `WifiNetworkSpecifier` (API 29+) via `ConnectivityManager.requestNetwork`, not
 * `WifiNetworkSuggestion` — a suggestion is a persistent "offer" the system may or may
 * not act on later; a specifier requests an *immediate*, one-time connection to a
 * specific network, which matches "I have credentials right now, connect to exactly
 * this network" better than a standing suggestion would. No special permission needed
 * (unlike the *providing* side's `NETWORK_SETTINGS`-gated credential read) — this is a
 * normal public API for exactly this use case.
 */
object HotspotAutoConnect {
    /** Requests a connection to the network described by [ssid]/[passphrase] and binds
     *  the process's default network to it on success, so subsequent traffic (e.g. the
     *  very connectivity check that triggered this in the first place) actually routes
     *  through it. Calls [onResult] with `true` on success, `false` on failure/timeout.
     *  The returned [NetworkCallback] must be kept alive (and eventually passed to
     *  [ConnectivityManager.unregisterNetworkCallback]) for as long as the connection
     *  should be held — releasing it lets the system tear the connection back down. */
    fun connect(
        context: Context,
        ssid: String,
        passphrase: String,
        onResult: (Boolean) -> Unit
    ): ConnectivityManager.NetworkCallback? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            Log.w(TAG, "WifiNetworkSpecifier requires API 29+")
            onResult(false)
            return null
        }
        val connectivityManager = context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val specifier = WifiNetworkSpecifier.Builder()
            .setSsid(ssid)
            .setWpa2Passphrase(passphrase)
            .build()
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()

        var settled = false
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                if (settled) return
                settled = true
                connectivityManager.bindProcessToNetwork(network)
                Log.i(TAG, "Connected to $ssid via WifiNetworkSpecifier")
                onResult(true)
            }

            override fun onUnavailable() {
                if (settled) return
                settled = true
                Log.w(TAG, "Could not connect to $ssid (unavailable/timed out/rejected)")
                onResult(false)
            }
        }
        connectivityManager.requestNetwork(request, callback)
        return callback
    }

    /** Releases a connection previously established by [connect] and unbinds the
     *  process's default network — call once this device's own reason for being on
     *  that network (e.g. reaching the mesh) is done, otherwise the system may keep
     *  holding a Wi-Fi connection open indefinitely on this app's behalf. */
    fun disconnect(context: Context, callback: ConnectivityManager.NetworkCallback) {
        val connectivityManager = context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        connectivityManager.bindProcessToNetwork(null)
        runCatching { connectivityManager.unregisterNetworkCallback(callback) }
    }
}
