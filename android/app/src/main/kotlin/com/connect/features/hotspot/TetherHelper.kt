package com.connect.features.hotspot

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.IIntResultListener
import android.net.ITetheringConnector
import android.net.TetheringManagerHidden
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import androidx.core.content.ContextCompat
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import rikka.shizuku.Shizuku
import rikka.shizuku.ShizukuBinderWrapper
import rikka.shizuku.SystemServiceHelper
import java.lang.reflect.Proxy
import java.util.concurrent.Executor
import kotlin.coroutines.resume

/**
 * Turns this phone's Wi-Fi hotspot on/off. Two completely different mechanisms depending
 * on OS version, because Android 16 tightened what used to work:
 *
 * **Android 10–15**: reflection against `ConnectivityManager`/`TetheringManager.
 * startTethering`/`stopTethering`, gated on the `WRITE_SECURE_SETTINGS` permission — the
 * same hidden framework path real third-party "toggle my phone's hotspot" apps use
 * (verified directly against SimpleWear's open-source `TetherHelper.kt`, not guessed).
 * That permission has no runtime-dialog equivalent: it must be granted once via `adb
 * shell pm grant <pkg> android.permission.WRITE_SECURE_SETTINGS` (the same well-established
 * mechanism automation apps like Tasker use — not root). **Confirmed still sufficient on
 * this range** — the harder lockdown below is Android-16-specific, not a general trend.
 *
 * **Android 16+**: `WRITE_SECURE_SETTINGS` alone is confirmed insufficient (verified
 * exhaustively on real Samsung/API 36 hardware this session — both `TetheringManager.
 * startTethering` attempts, entitlement-exempt and the SimpleWear-style retry without it,
 * fail with error 14/`TETHER_ERROR_NO_CHANGE_TETHERING_PERMISSION`; even `adb shell cmd
 * wifi start-softap` itself is denied with a `SecurityException`). Android 16 requires the
 * signature-only `TETHER_PRIVILEGED` permission, which nothing short of Shizuku or root
 * grants a normal app. This uses [ShizukuManager] to get a shell-UID Binder handle, then
 * calls the raw hidden `ITetheringConnector` AIDL interface directly (not the public
 * `TetheringManager` wrapper, which ties the call to this app's own real identity/UID and
 * is exactly what gets rejected) with the caller package spoofed as `"com.android.shell"`
 * — confirmed via a real, currently-maintained reference app (`github.com/supershadoe/
 * delta`) and mirrored by SimpleWear's own `wearsettings` companion app. See
 * `docs/ble-hotspot-protocol.md`'s "Open blocker" section for the full research trail.
 *
 * There is **no separate low-`targetSdk` "helper APK"** here — SimpleWear's `wearsettings`
 * module (initially assumed to be that) turns out to use this exact same Shizuku/raw-AIDL
 * technique itself, just with an additional pre-Android-11 `IConnectivityManager` fallback
 * this app doesn't need (Android 10–15 already works via the simpler `WRITE_SECURE_
 * SETTINGS` path above).
 */
object TetherHelper {
    private const val TAG = "TetherHelper"

    /** The OS version [setHotspotEnabled] switches from the plain `WRITE_SECURE_SETTINGS`
     *  path to the Shizuku/raw-AIDL path. Android 16 is API level 36; no named
     *  `Build.VERSION_CODES` constant is used here since this project's `compileSdk` (34)
     *  predates it. */
    private const val ANDROID_16 = 36

    private const val WIFI_AP_STATE_DISABLING = 10
    private const val WIFI_AP_STATE_DISABLED = 11
    private const val WIFI_AP_STATE_ENABLING = 12
    private const val WIFI_AP_STATE_ENABLED = 13
    private const val WIFI_AP_STATE_FAILED = 14

    private const val TETHERING_WIFI = 0
    private const val TETHERING_SERVICE = "tethering"

    enum class ToggleResult { SUCCESS, FAILURE, PERMISSION_DENIED, SHIZUKU_NOT_READY }

    fun isHotspotCapable(context: Context, shizukuManager: ShizukuManager? = null): Boolean =
        hasWriteSettingsPermission(context) || shizukuManager?.state?.value == ShizukuManager.State.CONNECTED

    /** The real gate `TetheringManager.startTethering`'s entitlement-exemption path checks
     *  — confirmed by reading SimpleWear's actual source after `WRITE_SECURE_SETTINGS` alone
     *  (this project's original, wrong assumption) failed live with error 14. Granted either
     *  via `Settings.ACTION_MANAGE_WRITE_SETTINGS` (normal special-access screen, the same
     *  category as "Display over other apps") or `adb shell appops set <pkg>
     *  android:write_settings allow` once declared in the manifest. */
    private fun hasWriteSettingsPermission(context: Context): Boolean = Settings.System.canWrite(context)

    fun requestWriteSettingsIntent(context: Context): android.content.Intent =
        android.content.Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS)
            .setData(android.net.Uri.parse("package:${context.packageName}"))

    fun isHotspotEnabled(context: Context): Boolean {
        val state = getWifiApState(context)
        return state == WIFI_AP_STATE_ENABLED || state == WIFI_AP_STATE_ENABLING
    }

    private fun getWifiApState(context: Context): Int = runCatching {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_WIFI_STATE) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return WIFI_AP_STATE_FAILED
        }
        val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val method = wifiManager.javaClass.getMethod("getWifiApState")
        method.invoke(wifiManager) as Int
    }.onFailure { Log.w(TAG, "Error getting Wi-Fi AP state", it) }.getOrDefault(WIFI_AP_STATE_FAILED)

    /** Suspends until the toggle attempt finishes (or [timeoutMs] elapses). Must be called
     *  from a coroutine — the underlying platform APIs are callback-based.
     *
     *  [shizukuManager] is optional — pass it whenever it's available (it's how the caller
     *  opts into the fallback below). On Android 16+ it's required; on 10–15 it's a
     *  best-effort fallback if the plain path fails.
     *
     *  TODO(onboarding): this currently guesses which mechanism to try from `Build.
     *  VERSION.SDK_INT` alone (see [ANDROID_16]), based on evidence gathered this session
     *  that's genuinely mixed across OEMs/versions (some reports show `TETHER_PRIVILEGED`
     *  enforced even pre-16 on certain devices). Once there's an onboarding flow for this
     *  feature, it should actually *probe* which mechanism works on the user's specific
     *  device/OS build (try the cheap path, fall back and remember the result) rather than
     *  assuming from SDK level — the version gate here is a reasonable default, not a
     *  guarantee. */
    suspend fun setHotspotEnabled(
        context: Context,
        enable: Boolean,
        shizukuManager: ShizukuManager? = null,
        timeoutMs: Long = 10_000
    ): ToggleResult {
        if (Build.VERSION.SDK_INT >= ANDROID_16) {
            // Confirmed dead on this OS version (see class doc) — don't waste a timeout
            // window on the plain path first.
            return setHotspotEnabledViaShizuku(shizukuManager, enable, timeoutMs)
        }
        if (hasWriteSettingsPermission(context)) {
            val result = withTimeoutOrNull(timeoutMs) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    if (enable) startTethering(context) else stopTethering(context)
                } else {
                    startOrStopTetheringPreR(context, enable)
                }
            }
            if (result == true) return ToggleResult.SUCCESS
            Log.w(TAG, "WRITE_SECURE_SETTINGS path failed or timed out; falling back to Shizuku if available")
        } else {
            Log.w(TAG, "WRITE_SETTINGS (Settings.System.canWrite) not granted; falling back to Shizuku if available")
        }
        return setHotspotEnabledViaShizuku(shizukuManager, enable, timeoutMs)
    }

    /** The Android-16+ path (see class doc): a shell-UID Binder via Shizuku, calling the
     *  raw hidden `ITetheringConnector` AIDL interface directly with the caller package
     *  spoofed as [ADB_PACKAGE_NAME] — not the public `TetheringManager` wrapper, which
     *  ties the call to this app's own real identity and is exactly what Android 16
     *  rejects. [TetheringManagerHidden]'s calls are bytecode-rewritten to the real
     *  hidden `android.net.TetheringManager` at build time by the Refine Gradle plugin
     *  (see `app/build.gradle.kts`) — the `throw RuntimeException("stub!")` bodies in the
     *  vendored stub source are never actually reached. */
    private suspend fun setHotspotEnabledViaShizuku(
        shizukuManager: ShizukuManager?,
        enable: Boolean,
        timeoutMs: Long
    ): ToggleResult {
        if (shizukuManager == null || shizukuManager.state.value != ShizukuManager.State.CONNECTED) {
            Log.w(TAG, "Shizuku not connected; cannot toggle hotspot")
            return ToggleResult.SHIZUKU_NOT_READY
        }
        val result = withTimeoutOrNull(timeoutMs) {
            suspendCancellableCoroutine<Boolean> { continuation ->
                runCatching {
                    val binder = SystemServiceHelper.getSystemService(TETHERING_SERVICE)
                        ?: error("Unable to get system service: $TETHERING_SERVICE")
                    val tetheringConnector = ITetheringConnector.Stub.asInterface(ShizukuBinderWrapper(binder))
                    val listener = object : IIntResultListener.Stub() {
                        override fun onResult(resultCode: Int) {
                            Log.i(TAG, "Shizuku tethering result: $resultCode")
                            if (continuation.isActive) continuation.resume(resultCode == TETHER_ERROR_NO_ERROR)
                        }
                    }
                    if (enable) {
                        val request = TetheringManagerHidden.TetheringRequest.Builder(TETHERING_WIFI)
                            .setExemptFromEntitlementCheck(true)
                            .setShouldShowEntitlementUi(false)
                            .build()
                        tetheringConnector.startTethering(request.parcel, ADB_PACKAGE_NAME, "", listener)
                    } else {
                        tetheringConnector.stopTethering(TETHERING_WIFI, ADB_PACKAGE_NAME, "", listener)
                    }
                }.onFailure {
                    Log.w(TAG, "Shizuku tethering call failed", it)
                    if (continuation.isActive) continuation.resume(false)
                }
            }
        }
        return if (result == true) ToggleResult.SUCCESS else ToggleResult.FAILURE
    }

    @Suppress("DEPRECATION")
    private fun startOrStopTetheringPreR(context: Context, enable: Boolean): Boolean = runCatching {
        val cm = context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        if (!enable) {
            val method = cm.javaClass.getMethod("stopTethering", Int::class.java)
            method.invoke(cm, TETHERING_WIFI)
            return true
        }
        true.also {
            val callbackClass = Class.forName("android.net.ConnectivityManager\$OnStartTetheringCallback")
            val method = cm.javaClass.getMethod(
                "startTethering",
                Int::class.java,
                Boolean::class.java,
                callbackClass,
                Handler::class.java
            )
            val proxy = Proxy.newProxyInstance(callbackClass.classLoader, arrayOf(callbackClass)) { _, _, _ -> null }
            method.invoke(cm, TETHERING_WIFI, false, proxy, Handler(Looper.getMainLooper()))
        }
    }.onFailure { Log.w(TAG, "startOrStopTetheringPreR failed", it) }.getOrDefault(false)

    private const val TETHER_ERROR_NO_CHANGE_TETHERING_PERMISSION = 14
    private const val TETHER_ERROR_NO_ERROR = 0

    /** Caller package spoofed on every Shizuku/raw-AIDL tethering call — matches Delta's
     *  and SimpleWear's own constant. Running as shell UID *and* asserting this identity
     *  together are what satisfy the check that rejects this app's own real identity. */
    private const val ADB_PACKAGE_NAME = "com.android.shell"

    private suspend fun startTethering(context: Context, allowRetry: Boolean = true): Boolean =
        suspendCancellableCoroutine { continuation ->
            runCatching {
                val tetheringManager = context.applicationContext.getSystemService(TETHERING_SERVICE)
                val tetheringManagerClass = Class.forName("android.net.TetheringManager")
                val requestClass = Class.forName("android.net.TetheringManager\$TetheringRequest")
                val requestBuilderClass = Class.forName("android.net.TetheringManager\$TetheringRequest\$Builder")
                val callbackClass = Class.forName("android.net.TetheringManager\$StartTetheringCallback")

                // First attempt exempts the entitlement check (the common case for a normal
                // carrier plan); if that's specifically what's rejected (error 14), SimpleWear's
                // reference implementation retries once without the exemption rather than
                // giving up — mirrored here.
                val request = requestBuilderClass.getConstructor(Int::class.java)
                    .newInstance(TETHERING_WIFI)
                    .let { builder ->
                        requestBuilderClass.getMethod("setExemptFromEntitlementCheck", Boolean::class.java)
                            .invoke(builder, allowRetry)
                        requestBuilderClass.getMethod("setShouldShowEntitlementUi", Boolean::class.java)
                            .invoke(builder, false)
                        requestBuilderClass.getMethod("build").invoke(builder)
                    }

                val proxy = Proxy.newProxyInstance(callbackClass.classLoader, arrayOf(callbackClass)) { _, method, args ->
                    when (method?.name) {
                        "onTetheringStarted" -> if (continuation.isActive) continuation.resume(true)
                        "onTetheringFailed" -> {
                            val code = (args?.getOrNull(0) as? Int) ?: -1
                            Log.w(
                                TAG,
                                "onTetheringFailed: code=$code" +
                                    if (code == TETHER_ERROR_NO_CHANGE_TETHERING_PERMISSION) " (entitlement check rejected; will retry without exemption)" else ""
                            )
                            if (continuation.isActive) continuation.resume(false)
                        }
                    }
                    null
                }

                val startMethod = tetheringManagerClass.getMethod(
                    "startTethering", requestClass, Executor::class.java, callbackClass
                )
                startMethod.invoke(tetheringManager, request, Executor { it.run() }, proxy)
            }.onFailure {
                Log.w(TAG, "startTethering failed", it)
                if (continuation.isActive) continuation.resume(false)
            }
        }.let { result ->
            if (!result && allowRetry) startTethering(context, allowRetry = false) else result
        }

    private fun stopTethering(context: Context): Boolean = runCatching {
        val tetheringManager = context.applicationContext.getSystemService(TETHERING_SERVICE)
        val tetheringManagerClass = Class.forName("android.net.TetheringManager")
        val method = tetheringManagerClass.getMethod("stopTethering", Int::class.java)
        method.invoke(tetheringManager, TETHERING_WIFI)
        true
    }.onFailure { Log.w(TAG, "stopTethering failed", it) }.getOrDefault(false)
}
