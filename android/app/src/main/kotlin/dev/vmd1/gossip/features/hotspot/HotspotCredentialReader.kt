package dev.vmd1.gossip.features.hotspot

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import android.util.Log
import rikka.shizuku.ShizukuBinderWrapper
import rikka.shizuku.SystemServiceHelper

/**
 * Reads this phone's *active* hotspot SSID/passphrase so they can be handed to a
 * requesting device for auto-connect (`docs/ble-hotspot-protocol.md`'s credential
 * auto-connect design). `WifiManager.getSoftApConfiguration()` (API 30+) is the real API
 * for this, but it and `SoftApConfiguration` itself are `@SystemApi` — not in the public
 * SDK stub jar at all (a direct typed call fails to *compile* against `compileSdk 36`'s
 * public android.jar, confirmed directly) — and the method requires the caller to hold
 * `NETWORK_SETTINGS`/`NETWORK_SETUP_WIZARD`, which a normal app's own UID never has:
 * confirmed live on real hardware (Samsung SM-S711B, Android 16) via a temporary debug
 * broadcast — a plain reflective call through this app's own `WifiManager` instance fails
 * with `SecurityException: App not allowed to read or update stored WiFi Ap config`.
 *
 * **The Shizuku path works**, also confirmed live: unlike the hotspot *toggle*
 * (`ShizukuHotspotMechanism`), which has to spoof the caller package as
 * `"com.android.shell"` on a *parameter* the `ITetheringConnector` AIDL call takes,
 * `IWifiManager.getSoftApConfiguration()` takes no parameters at all — the permission
 * check is purely against the Binder transaction's calling UID, and a
 * [ShizukuBinderWrapper]-wrapped call runs with Shizuku's shell UID as that calling
 * identity, which already holds `NETWORK_SETTINGS`. No vendored AIDL stub was needed:
 * `IWifiManager` is a real on-device class, just not a public one, so
 * `IWifiManager.Stub.asInterface(...)` and the result's `getSoftApConfiguration()` are
 * called here via plain reflection (mirroring `TetherHelper.getWifiApState`'s existing
 * reflection pattern, one level deeper). Live result: real SSID and a real 9-character
 * passphrase read back successfully from this app's own active hotspot.
 *
 * Falls back to the direct (non-Shizuku) call when [shizukuManager] is absent/not
 * connected — harmless to attempt (costs nothing, might work on some more permissive
 * OEM/AOSP build), but expected to fail with the `SecurityException` above in the common
 * case. Either way, a `null` result here just means the `hotspot.status` response omits
 * `ssid`/`pass` and the requester falls back to a manual connect — the toggle itself
 * (`TetherHelper.setHotspotEnabled`) already fully succeeds independent of this.
 */
object HotspotCredentialReader {
    private const val TAG = "HotspotCredentialReader"
    private const val WIFI_SERVICE_NAME = "wifi"

    data class Credentials(val ssid: String, val passphrase: String)

    fun readCredentials(context: Context, shizukuManager: ShizukuManager? = null): Credentials? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
        if (shizukuManager?.state?.value == ShizukuManager.State.CONNECTED) {
            readViaShizuku()?.let { return it }
        }
        return readDirect(context)
    }

    private fun readViaShizuku(): Credentials? = runCatching {
        val binder = SystemServiceHelper.getSystemService(WIFI_SERVICE_NAME) ?: return null
        val wrapped = ShizukuBinderWrapper(binder)
        val stubClass = Class.forName("android.net.wifi.IWifiManager\$Stub")
        val iWifiManager = stubClass.getMethod("asInterface", android.os.IBinder::class.java).invoke(null, wrapped)
        val config = iWifiManager.javaClass.getMethod("getSoftApConfiguration").invoke(iWifiManager) ?: return null
        extractCredentials(config)
    }.onFailure {
        Log.w(TAG, "Shizuku-brokered getSoftApConfiguration() failed", it)
    }.getOrNull()

    private fun readDirect(context: Context): Credentials? = runCatching {
        val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val config = wifiManager.javaClass.getMethod("getSoftApConfiguration").invoke(wifiManager) ?: return null
        extractCredentials(config)
    }.onFailure {
        Log.w(TAG, "Direct getSoftApConfiguration() failed (expected without NETWORK_SETTINGS)", it)
    }.getOrNull()

    /** [config] is an `android.net.wifi.SoftApConfiguration` instance, accessed purely via
     *  reflection since the class isn't in the public SDK. `getSsid()` returns a
     *  `WifiSsid` object (not a `CharSequence`) whose `toString()` renders it
     *  double-quoted, e.g. `"Vivaan"` — confirmed live — so the quotes are stripped here
     *  rather than assumed away. */
    private fun extractCredentials(config: Any): Credentials? {
        val configClass = config.javaClass
        val ssidRaw = configClass.getMethod("getSsid").invoke(config) ?: return null
        val ssid = ssidRaw.toString().trim('"')
        val passphrase = configClass.getMethod("getPassphrase").invoke(config) as? String ?: return null
        if (ssid.isEmpty() || passphrase.isEmpty()) return null
        return Credentials(ssid, passphrase)
    }
}
